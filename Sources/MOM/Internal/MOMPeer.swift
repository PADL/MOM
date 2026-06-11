//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif
import Dispatch
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// I/O driver for one TCP-connected MOM peer. Wires `DispatchSource`s on
/// the peer's socket fd to the controller's queue.
///
/// All methods run on (or are dispatched to) the controller's queue.
enum MOMPeer {
  static let readChunk = 1024

  /// Set up read/write sources on `peer.fd` and attach them to the
  /// controller's queue. Caller has already added `peer` to the controller.
  static func start(_ peer: MOMPeerContext) {
    guard let controller = peer.controller else { return }
    let q = controller.queue

    let readSrc = IOReadinessSource.read(fd: peer.fd, queue: q)
    readSrc.setEventHandler { [weak peer] in
      guard let p = peer else { return }
      handleReadable(p)
    }
    readSrc.setCancelHandler { [fd = peer.fd] in
      Socket.close(fd)
    }
    peer.readSource = readSrc

    let writeSrc = IOReadinessSource.write(fd: peer.fd, queue: q)
    writeSrc.setEventHandler { [weak peer] in
      guard let p = peer else { return }
      flushWrite(p)
    }
    peer.writeSource = writeSrc

    readSrc.resume()
    // writeSource is resumed lazily when there's data to send

    peer.lastActivity = Date()
    controller._setPeerPortStatus(peer, .open)
  }

  /// Called by `MOMController._enqueueMessage`. Appends to the buffer and
  /// makes sure the write source is running.
  static func enqueue(_ peer: MOMPeerContext, _ data: Data) {
    peer.writeBuffer.append(data)
    if !peer.writeSourceActive, let src = peer.writeSource {
      peer.writeSourceActive = true
      src.resume()
    }
  }

  // MARK: - Read path

  private static func handleReadable(_ peer: MOMPeerContext) {
    var buf = [UInt8](repeating: 0, count: readChunk)
    let n = buf.withUnsafeMutableBufferPointer { p in
      Socket.recvRaw(numericCast(peer.fd), p.baseAddress, p.count)
    }

    if n == 0 {
      close(peer, error: nil)
      return
    }
    if n < 0 {
      let err = errno
      if errWouldBlock(err) || errInterrupted(err) { return }
      close(peer, error: err)
      return
    }

    peer.lastActivity = Date()
    peer.readBuffer.append(buf, count: Int(n))
    drainMessages(peer)
  }

  /// Split the read buffer on '\r'. Each complete message is parsed and
  /// dispatched. Trailing partial message stays in the buffer.
  ///
  /// Scans with a moving index and trims the consumed prefix once at the
  /// end: DADman pipelines dozens of requests per read during init, and a
  /// per-message front-removal would be O(messages × buffer).
  private static func drainMessages(_ peer: MOMPeerContext) {
    guard let controller = peer.controller else { return }

    let buf = peer.readBuffer
    var scanStart = buf.startIndex
    while let crIdx = buf[scanStart...].firstIndex(of: MOMMessage.recordTerminator) {
      let message = buf[scanStart..<crIdx]
      scanStart = buf.index(after: crIdx)

      if message.isEmpty { continue }

      switch MOMMessage.decode(Data(message)) {
      case let .ok(event, params):
        if event.type.rawValue & MOMEvent.typeHostAny.rawValue != 0 {
          controller._processEvent(peer: peer, eventWithType: event, params: params)
        }
      case let .unknownRequest(reply):
        controller._enqueueMessage(peer, reply)
      case .invalid:
        break // ignore, match C
      }
    }
    peer.readBuffer.removeSubrange(buf.startIndex..<scanStart)
  }

  // MARK: - Write path

  private static func flushWrite(_ peer: MOMPeerContext) {
    while peer.bytesWritten < peer.writeBuffer.count {
      let remaining = peer.writeBuffer.count - peer.bytesWritten
      let n = peer.writeBuffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
        let p = raw.baseAddress!.advanced(by: peer.bytesWritten)
        return Socket.sendRaw(numericCast(peer.fd), p, remaining)
      }
      if n < 0 {
        let err = errno
        if errWouldBlock(err) { return }
        if errInterrupted(err) { continue }
        close(peer, error: err)
        return
      }
      if n == 0 { return }
      peer.bytesWritten += n
    }
    // fully drained
    peer.writeBuffer.removeAll(keepingCapacity: true)
    peer.bytesWritten = 0
    suspendWriteSource(peer)
  }

  private static func suspendWriteSource(_ peer: MOMPeerContext) {
    if peer.writeSourceActive, let src = peer.writeSource {
      src.suspend()
      peer.writeSourceActive = false
    }
  }

  // MARK: - Close

  /// Tear down both sources, close the fd (via the cancel handler), drop
  /// the peer from the controller's peer list, and notify the application
  /// handler of the port-state transition.
  static func close(_ peer: MOMPeerContext, error: Int32?) {
    guard !peer.closed else { return }
    peer.closed = true
    let reason = error.map { " (errno \($0): \(errnoToString($0)))" } ?? ""
    (peer.controller?.logger ?? defaultLogger)
      .debug("closing peer \(peer.peerName ?? "?")\(reason)")

    if let c = peer.controller {
      if c._isPeerMaster(peer) { c._setMasterPeer(nil) }
      if c._peerPortStatus(peer).rawValue >= MOMPortStatus.open.rawValue {
        c._setPeerPortStatus(peer, .closed, error: error)
      }
      c._removePeer(peer)
    }

    // suspended sources must be resumed before cancel
    if !peer.writeSourceActive, let w = peer.writeSource {
      w.resume()
    }
    peer.writeSource?.cancel()
    peer.readSource?.cancel()
    peer.writeSource = nil
    peer.readSource = nil
  }
}
