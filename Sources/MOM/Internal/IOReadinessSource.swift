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

import Synchronization
import WinSDK

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
///
/// The poll blocks indefinitely: a loopback "self-wake" UDP socket sits in
/// the poll set, and every state change that alters what should be polled
/// (activate/deactivate/cancel, and the inFlight reset after a handler runs)
/// sends it a byte. No periodic wakeups, no idle CPU.
final class WSAPoller: @unchecked Sendable {
  static let shared = WSAPoller()

  // Guards `active`, `started`, and every source's mutable fields. The
  // protected value is Void: the state lives on the poller and the sources,
  // and the mutex provides the critical sections.
  let lock = Mutex<Void>(())
  private var active: [IOReadinessSource] = []
  private var started = false

  // Self-wake pair: `wakeTx` is connected to `wakeRx`, which is bound to an
  // ephemeral loopback port, non-blocking, and always in the poll set.
  private var wakeRx: SOCKET = INVALID_SOCKET
  private var wakeTx: SOCKET = INVALID_SOCKET

  /// Fallback poll cadence (ms), used only if the self-wake pair could not
  /// be created; otherwise the poll blocks until woken.
  private let fallbackTimeoutMs: INT = 20

  private init() {
    _ensureWinsock()
    let rx = socket(AF_INET, Socket.datagramType, 0)
    let tx = socket(AF_INET, Socket.datagramType, 0)
    var sin = Socket.ipv4Address(port: 0, address: INADDR_LOOPBACK.bigEndian)
    let ok = rx != INVALID_SOCKET && tx != INVALID_SOCKET && sin.withSockaddr { sa, saLen in
      var len = saLen
      return bind(rx, sa, saLen) == 0
        && getsockname(rx, sa, &len) == 0
        && connect(tx, sa, saLen) == 0
    }
    guard ok else {
      if rx != INVALID_SOCKET { closesocket(rx) }
      if tx != INVALID_SOCKET { closesocket(tx) }
      return
    }
    Socket.makeNonBlocking(rx)
    wakeRx = rx
    wakeTx = tx
  }

  /// Interrupt a blocked `WSAPoll` so the next iteration sees current state.
  private func wake() {
    guard wakeTx != INVALID_SOCKET else { return }
    var byte: CChar = 0
    _ = send(wakeTx, &byte, 1, 0)
  }

  func setEventHandler(_ source: IOReadinessSource, _ handler: @escaping @Sendable () -> ()) {
    lock.withLock { _ in source.eventHandler = handler }
  }

  func setCancelHandler(_ source: IOReadinessSource, _ handler: @escaping @Sendable () -> ()) {
    lock.withLock { _ in source.cancelHandler = handler }
  }

  func activate(_ source: IOReadinessSource) {
    lock.withLock { _ in
      guard source.state != .cancelled else { return }
      source.state = .active
      if !active.contains(where: { $0 === source }) {
        active.append(source)
      }
      startIfNeededLocked()
    }
    wake()
  }

  func deactivate(_ source: IOReadinessSource) {
    lock.withLock { _ in
      guard source.state != .cancelled else { return }
      source.state = .suspended
      active.removeAll { $0 === source }
    }
    wake()
  }

  func cancel(_ source: IOReadinessSource) {
    var handler: (@Sendable () -> ())?
    let cancelled: Bool = lock.withLock { _ in
      guard source.state != .cancelled else { return false }
      source.state = .cancelled
      active.removeAll { $0 === source }
      handler = source.cancelHandler
      return true
    }
    guard cancelled else { return }
    wake()
    // Match DispatchSource: the cancel handler runs asynchronously on the
    // queue (it closes the fd).
    source.queue.async { [handler] in handler?() }
  }

  func isCancelled(_ source: IOReadinessSource) -> Bool {
    lock.withLock { _ in source.state == .cancelled }
  }

  /// Called with `lock` held.
  private func startIfNeededLocked() {
    guard !started else { return }
    started = true
    // A raw Win32 thread, so the poller has no Foundation dependency. The
    // retain handed to the thread is deliberately never balanced: the
    // poller is a process-lifetime singleton and `run()` never returns.
    let context = Unmanaged.passRetained(self).toOpaque()
    let thread = CreateThread(nil, SIZE_T(1 << 20), { context in
      Unmanaged<WSAPoller>.fromOpaque(context!).takeUnretainedValue().run()
      return 0
    }, context, 0, nil)
    if let thread { CloseHandle(thread) }
  }

  private func run() {
    "MOM.WSAPoller".withCString(encodedAs: UTF16.self) {
      _ = SetThreadDescription(GetCurrentThread(), $0)
    }

    let hasWake = wakeRx != INVALID_SOCKET
    let timeout: INT = hasWake ? -1 : fallbackTimeoutMs // -1: block until woken
    var drain = [CChar](repeating: 0, count: 64)

    while true {
      let pollable = lock.withLock { _ in
        active.filter { $0.state == .active && !$0.inFlight }
      }

      if pollable.isEmpty, !hasWake {
        Sleep(DWORD(fallbackTimeoutMs))
        continue
      }

      var fds: [WSAPOLLFD] = []
      fds.reserveCapacity(pollable.count + 1)
      if hasWake {
        var pfd = WSAPOLLFD()
        pfd.fd = wakeRx
        pfd.events = SHORT(POLLRDNORM)
        fds.append(pfd)
      }
      for source in pollable {
        var pfd = WSAPOLLFD()
        pfd.fd = source.fd
        pfd.events = SHORT(source.kind == .read ? POLLRDNORM : POLLWRNORM)
        fds.append(pfd)
      }

      let ready = WSAPoll(&fds, ULONG(fds.count), timeout)
      if ready < 0 {
        // WSAPoll itself failed (not a per-fd POLLNVAL, which arrives in
        // revents); back off rather than spinning hot on a persistent error.
        Sleep(DWORD(fallbackTimeoutMs))
        continue
      }
      guard ready > 0 else { continue }

      let base = hasWake ? 1 : 0
      if hasWake, fds[0].revents != 0 {
        // Swallow accumulated wake bytes; the fresh `pollable` snapshot at
        // the top of the loop is the actual response.
        while recv(wakeRx, &drain, Int32(drain.count), 0) > 0 {}
      }

      for (index, pfd) in fds.enumerated().dropFirst(base) where pfd.revents != 0 {
        // Any nonzero revents (data, or POLLHUP/POLLERR/POLLNVAL) wakes the
        // handler so it can observe EOF/errors via recv/send.
        let source = pollable[index - base]
        var handler: (@Sendable () -> ())?
        let claimed: Bool = lock.withLock { _ in
          guard source.state == .active, !source.inFlight else { return false }
          source.inFlight = true
          handler = source.eventHandler
          return true
        }
        guard claimed else { continue }

        // `source` is captured strongly so the inFlight latch is always
        // cleared. Re-check state on the queue before delivering: a cancel
        // enqueued between our unlock and this block running may already
        // have closed the fd (and the kernel may have reused it), and a
        // suspended source must not fire — level-triggered polling will
        // rediscover readiness after resume().
        source.queue.async { [handler] in
          let poller = WSAPoller.shared
          let deliver = poller.lock.withLock { _ in source.state == .active }
          if deliver { handler?() }
          poller.lock.withLock { _ in source.inFlight = false }
          // The poll may be blocked indefinitely; nudge it so this source
          // re-enters the poll set now that its handler has drained.
          poller.wake()
        }
      }
    }
  }
}

#endif
