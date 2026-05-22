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

/// TCP listen socket on `MOMPort.control`. Accepts incoming connections,
/// builds a `MOMPeerContext` per accepted peer, and starts its I/O sources.
internal final class MOMListener: @unchecked Sendable {
  let fd: Int32
  let source: DispatchSourceRead
  let port: UInt16

  /// Returns nil on socket/bind/listen failure.
  static func bind(on port: UInt16,
                   address: in_addr_t,
                   controller: MOMController) -> MOMListener? {
    let fd = socket(AF_INET, sockType_stream, 0)
    if fd < 0 { return nil }

    _ = MOMNet.setReuseAddress(fd)

    guard MOMNet.bind(fd, port: port, address: address) else {
      MOMNet.close(fd)
      return nil
    }

    if listen(fd, 16) != 0 {
      MOMNet.close(fd)
      return nil
    }

    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: controller.queue)
    let listener = MOMListener(fd: fd, source: src, port: port)

    src.setEventHandler { [weak controller] in
      guard let c = controller else { return }
      listener.acceptConnection(controller: c)
    }
    src.setCancelHandler {
      MOMNet.close(fd)
    }
    src.resume()
    return listener
  }

  private init(fd: Int32, source: DispatchSourceRead, port: UInt16) {
    self.fd = fd
    self.source = source
    self.port = port
  }

  func invalidate() {
    source.cancel()
  }

  // MARK: - Accept

  private func acceptConnection(controller: MOMController) {
    var sin = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let clientFD = withUnsafeMutablePointer(to: &sin) { sp in
      sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        accept(fd, sa, &len)
      }
    }
    if clientFD < 0 { return }

    if sin.sin_family != sa_family_t(AF_INET) {
      MOMNet.close(clientFD)
      return
    }

    let peerName = MOMListener.formatIPv4(sin.sin_addr)
    let peer = MOMPeerContext(controller: controller,
                              fd: clientFD,
                              peerAddress: sin,
                              peerName: peerName)

    // Host-restriction check. The controller's cached `_restrictAddresses`
    // is populated at init via `MOMResolver.resolveIPv4`, which handles
    // both IPv4 literals and hostnames.
    if !controller._peerAddressAllowed(sin.sin_addr) {
      MOMNet.close(clientFD)
      return
    }

    _ = MOMNet.setNoDelay(clientFD)
    MOMNet.makeNonBlocking(clientFD)

    controller._addPeer(peer)
    MOMPeer.start(peer)
  }

  // MARK: - Helpers

  static func formatIPv4(_ addr: in_addr) -> String {
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var a = addr
    let cstr = inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
    return cstr.map { String(cString: $0) } ?? ""
  }

  static func parseIPv4(_ s: String) -> in_addr_t? {
    var a = in_addr()
    return s.withCString { cstr in
      inet_pton(AF_INET, cstr, &a) == 1 ? a.s_addr : nil
    }
  }
}

// SOCK_STREAM is an Int32 enum on Darwin and a CInt elsewhere; alias it.
#if canImport(Darwin)
private let sockType_stream: Int32 = SOCK_STREAM
#else
private let sockType_stream: Int32 = Int32(SOCK_STREAM.rawValue)
#endif

internal extension MOMNet {
  /// O_NONBLOCK | existing fcntl flags.
  static func makeNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
  }
}
