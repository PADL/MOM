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
#endif
import Foundation

/// I/O driver for one TCP-connected MOM peer. Wires `DispatchSource`s on
/// the peer's socket fd to the controller's queue.
///
/// All methods run on (or are dispatched to) the controller's queue.
internal enum MOMPeer {
  static let readChunk = 1024

  /// Set up read/write sources on `peer.fd` and attach them to the
  /// controller's queue. Caller has already added `peer` to the controller.
  static func start(_ peer: MOMPeerContext) {
    guard let controller = peer.controller else { return }
    let q = controller.queue

    let readSrc = DispatchSource.makeReadSource(fileDescriptor: peer.fd, queue: q)
    readSrc.setEventHandler { [weak peer] in
      guard let p = peer else { return }
      handleReadable(p)
    }
    readSrc.setCancelHandler { [fd = peer.fd] in
      MOMNet.close(fd)
    }
    peer.readSource = readSrc

    let writeSrc = DispatchSource.makeWriteSource(fileDescriptor: peer.fd, queue: q)
    writeSrc.setEventHandler { [weak peer] in
      guard let p = peer else { return }
      flushWrite(p)
    }
    peer.writeSource = writeSrc

    readSrc.resume()
    // writeSource is resumed lazily when there's data to send

    peer.lastActivity = time(nil)
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
      read(peer.fd, p.baseAddress, p.count)
    }

    if n == 0 {
      close(peer, error: nil)
      return
    }
    if n < 0 {
      let err = momErrno
      if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { return }
      close(peer, error: err)
      return
    }

    peer.lastActivity = time(nil)
    peer.readBuffer.append(buf, count: Int(n))
    drainMessages(peer)
  }

  /// Split the read buffer on '\r'. Each complete message is parsed and
  /// dispatched. Trailing partial message stays in the buffer.
  private static func drainMessages(_ peer: MOMPeerContext) {
    guard let controller = peer.controller else { return }
    let CR: UInt8 = 0x0D

    while let crIdx = peer.readBuffer.firstIndex(of: CR) {
      let message = peer.readBuffer[peer.readBuffer.startIndex..<crIdx]
      peer.readBuffer.removeSubrange(peer.readBuffer.startIndex...crIdx)

      if message.isEmpty { continue }

      switch MOMMessage.decode(Data(message)) {
      case .ok(let event, let params):
        if event.type.rawValue & MOMEvent.typeHostAny.rawValue != 0 {
          controller._processEvent(peer: peer, eventWithType: event, params: params)
        }
      case .unknownRequest(let reply):
        controller._enqueueMessage(peer, reply)
      case .invalid:
        break  // ignore, match C
      }
    }
  }

  // MARK: - Write path

  private static func flushWrite(_ peer: MOMPeerContext) {
    while peer.bytesWritten < peer.writeBuffer.count {
      let remaining = peer.writeBuffer.count - peer.bytesWritten
      let n = peer.writeBuffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
        let p = raw.baseAddress!.advanced(by: peer.bytesWritten)
        return write(peer.fd, p, remaining)
      }
      if n < 0 {
        let err = momErrno
        if err == EAGAIN || err == EWOULDBLOCK { return }
        if err == EINTR { continue }
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

    if let c = peer.controller {
      if c._isPeerMaster(peer) { c._setMasterPeer(nil) }
      if c._peerPortStatus(peer).rawValue >= MOMPortStatus.open.rawValue {
        c._setPeerPortStatus(peer, .closed)
        c._notifyPortState(peer, status: .closed, error: error)
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
