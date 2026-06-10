//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

// A level-triggered readiness source over a socket fd, delivering events on a
// `DispatchQueue`. This is the one piece of the controller's Dispatch usage
// that does not survive on Windows: `DispatchSource.makeReadSource/
// makeWriteSource` fast-fail when created for a socket there. Everything else
// (DispatchQueue, DispatchSourceTimer, DispatchQueue.global) works, so the
// controller keeps its queue-serialized model and only the readiness sources
// are abstracted here.
//
// - Apple/Linux: a thin wrapper over the real DispatchSource (unchanged
//   behavior).
// - Windows: registration with a single background WSAPoll thread that
//   marshals readiness back onto the same queue via `queue.async`, preserving
//   the "everything runs serially on the controller queue" invariant.
//
// The surface mirrors the slice of DispatchSource the I/O code relies on:
// setEventHandler / setCancelHandler / resume / suspend / cancel / isCancelled.
// Sources start suspended; `resume()` begins delivery (matching DispatchSource).

import Dispatch
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if !canImport(WinSDK)

/// Apple/Linux backing: forward straight to a real DispatchSource.
final class IOReadinessSource: @unchecked Sendable {
  private let source: any DispatchSourceProtocol

  private init(_ source: any DispatchSourceProtocol) {
    self.source = source
  }

  static func read(fd: Socket.SocketDescriptor, queue: DispatchQueue) -> IOReadinessSource {
    IOReadinessSource(DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue))
  }

  static func write(fd: Socket.SocketDescriptor, queue: DispatchQueue) -> IOReadinessSource {
    IOReadinessSource(DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue))
  }

  func setEventHandler(_ handler: @escaping @Sendable () -> ()) {
    source.setEventHandler(handler: handler)
  }

  func setCancelHandler(_ handler: @escaping @Sendable () -> ()) {
    source.setCancelHandler(handler: handler)
  }

  func resume() { source.resume() }
  func suspend() { source.suspend() }
  func cancel() { source.cancel() }
  var isCancelled: Bool { source.isCancelled }
}

#else

import WinSDK
// The poller needs Thread and NSLock, which live in the full Foundation
// module, not FoundationEssentials.
import Foundation

/// Windows backing: a registration with `WSAPoller.shared`.
final class IOReadinessSource: @unchecked Sendable {
  enum Kind { case read, write }
  enum State { case suspended, active, cancelled }

  let fd: Socket.SocketDescriptor
  let kind: Kind
  let queue: DispatchQueue

  // All of the following are mutated only under `WSAPoller.shared.lock`.
  var state: State = .suspended
  var inFlight = false
  var eventHandler: (@Sendable () -> ())?
  var cancelHandler: (@Sendable () -> ())?

  private init(fd: Socket.SocketDescriptor, kind: Kind, queue: DispatchQueue) {
    self.fd = fd
    self.kind = kind
    self.queue = queue
  }

  static func read(fd: Socket.SocketDescriptor, queue: DispatchQueue) -> IOReadinessSource {
    IOReadinessSource(fd: fd, kind: .read, queue: queue)
  }

  static func write(fd: Socket.SocketDescriptor, queue: DispatchQueue) -> IOReadinessSource {
    IOReadinessSource(fd: fd, kind: .write, queue: queue)
  }

  func setEventHandler(_ handler: @escaping @Sendable () -> ()) {
    WSAPoller.shared.setEventHandler(self, handler)
  }

  func setCancelHandler(_ handler: @escaping @Sendable () -> ()) {
    WSAPoller.shared.setCancelHandler(self, handler)
  }

  func resume() { WSAPoller.shared.activate(self) }
  func suspend() { WSAPoller.shared.deactivate(self) }
  func cancel() { WSAPoller.shared.cancel(self) }
  var isCancelled: Bool { WSAPoller.shared.isCancelled(self) }
}

/// One process-wide background thread that `WSAPoll`s every active source and
/// dispatches readiness onto each source's queue. A per-source `inFlight`
/// latch keeps a still-readable socket from re-dispatching before its handler
/// (which runs asynchronously on the queue) has had a chance to drain it —
/// emulating DispatchSource's level-triggered-without-storms behavior.
final class WSAPoller: @unchecked Sendable {
  static let shared = WSAPoller()

  let lock = NSLock()
  private var active: [IOReadinessSource] = []
  private var started = false

  /// Poll wait, milliseconds. Bounds added/removed-source latency without a
  /// wakeup socket; fine for a control protocol, negligible idle CPU.
  private let pollTimeoutMs: INT = 20

  func setEventHandler(_ source: IOReadinessSource, _ handler: @escaping @Sendable () -> ()) {
    lock.lock(); defer { lock.unlock() }
    source.eventHandler = handler
  }

  func setCancelHandler(_ source: IOReadinessSource, _ handler: @escaping @Sendable () -> ()) {
    lock.lock(); defer { lock.unlock() }
    source.cancelHandler = handler
  }

  func activate(_ source: IOReadinessSource) {
    lock.lock(); defer { lock.unlock() }
    guard source.state != .cancelled else { return }
    source.state = .active
    if !active.contains(where: { $0 === source }) {
      active.append(source)
    }
    startIfNeededLocked()
  }

  func deactivate(_ source: IOReadinessSource) {
    lock.lock(); defer { lock.unlock() }
    guard source.state != .cancelled else { return }
    source.state = .suspended
    active.removeAll { $0 === source }
  }

  func cancel(_ source: IOReadinessSource) {
    lock.lock()
    guard source.state != .cancelled else { lock.unlock(); return }
    source.state = .cancelled
    active.removeAll { $0 === source }
    let handler = source.cancelHandler
    let queue = source.queue
    lock.unlock()
    // Match DispatchSource: the cancel handler runs asynchronously on the
    // queue (it closes the fd).
    queue.async { handler?() }
  }

  func isCancelled(_ source: IOReadinessSource) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return source.state == .cancelled
  }

  private func startIfNeededLocked() {
    guard !started else { return }
    started = true
    let thread = Thread { [weak self] in self?.run() }
    thread.name = "MOM.WSAPoller"
    thread.stackSize = 1 << 20
    thread.start()
  }

  private func run() {
    while true {
      lock.lock()
      let pollable = active.filter { $0.state == .active && !$0.inFlight }
      lock.unlock()

      if pollable.isEmpty {
        Sleep(DWORD(pollTimeoutMs))
        continue
      }

      var fds = pollable.map { source -> WSAPOLLFD in
        var pfd = WSAPOLLFD()
        pfd.fd = source.fd
        pfd.events = SHORT(source.kind == .read ? POLLRDNORM : POLLWRNORM)
        pfd.revents = 0
        return pfd
      }

      let ready = WSAPoll(&fds, ULONG(fds.count), pollTimeoutMs)
      if ready < 0 {
        // WSAPoll itself failed (not a per-fd POLLNVAL, which arrives in
        // revents); back off rather than spinning hot on a persistent error.
        Sleep(DWORD(pollTimeoutMs))
        continue
      }
      guard ready > 0 else { continue }

      for (index, pfd) in fds.enumerated() where pfd.revents != 0 {
        // Any nonzero revents (data, or POLLHUP/POLLERR/POLLNVAL) wakes the
        // handler so it can observe EOF/errors via recv/send.
        let source = pollable[index]
        lock.lock()
        guard source.state == .active, !source.inFlight else { lock.unlock(); continue }
        source.inFlight = true
        let handler = source.eventHandler
        let queue = source.queue
        lock.unlock()

        // `source` is captured strongly so the inFlight latch is always
        // cleared. Re-check state on the queue before delivering: a cancel
        // enqueued between our unlock and this block running may already
        // have closed the fd (and the kernel may have reused it), and a
        // suspended source must not fire — level-triggered polling will
        // rediscover readiness after resume().
        queue.async {
          let poller = WSAPoller.shared
          poller.lock.lock()
          let deliver = source.state == .active
          poller.lock.unlock()

          if deliver { handler?() }

          poller.lock.lock()
          source.inFlight = false
          poller.lock.unlock()
        }
      }
    }
  }
}

#endif
