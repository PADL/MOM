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

/// TCP listen socket on `MOMPort.control`. Accepts incoming connections,
/// builds a `MOMPeerContext` per accepted peer, and starts its I/O sources.
final class MOMListener: @unchecked Sendable {
  let fd: Socket.SocketDescriptor
  let source: IOReadinessSource
  let port: UInt16

  /// Returns nil on socket/bind/listen failure.
  static func bind(
    on port: UInt16,
    address: in_addr_t,
    controller: MOMController
  ) -> MOMListener? {
    guard let sock = Socket.tcp() else { return nil }
    sock.setReuseAddress()

    guard sock.bind(port: port, address: address), sock.listen(backlog: 16)
    else { return nil } // sock deinit closes the fd

    // Non-blocking so accept() in the DispatchSource handler doesn't stall
    // if the connection is reset between event fire and accept call.
    sock.makeNonBlocking()

    let fd = sock.detach()
    let src = IOReadinessSource.read(fd: fd, queue: controller.queue)
    let listener = MOMListener(fd: fd, source: src, port: port)

    src.setEventHandler { [weak listener, weak controller] in
      guard let listener, let c = controller else { return }
      listener.acceptConnection(controller: c)
    }
    src.setCancelHandler {
      Socket.close(fd)
    }
    src.resume()
    logger.debug("listening on TCP port \(port)")
    return listener
  }

  private init(fd: Socket.SocketDescriptor, source: IOReadinessSource, port: UInt16) {
    self.fd = fd
    self.source = source
    self.port = port
  }

  func invalidate() {
    source.cancel()
  }

  deinit {
    // Dropping the listener without invalidate() must still close the fd;
    // the source owns it via the cancel handler.
    if !source.isCancelled {
      source.cancel()
    }
  }

  // MARK: - Accept

  private func acceptConnection(controller: MOMController) {
    var sin = sockaddr_in()
    guard let client = Socket.acceptIPv4(on: fd, address: &sin) else { return }

    // Host-restriction check before any further setup. The controller's
    // cached `_restrictAddresses` is populated at init via
    // `MOMResolver.resolveIPv4`, which handles IPv4 literals and hostnames.
    guard controller._peerAddressAllowed(sin.sin_addr) else {
      logger.debug("rejected connection from \(Socket.format(sin.sin_addr)) (host restriction)")
      return // client deinit closes the rejected connection
    }

    client.setNoDelay()
    client.makeNonBlocking()

    let peer = MOMPeerContext(
      controller: controller,
      fd: client.detach(),
      peerAddress: sin,
      peerName: Socket.format(sin.sin_addr)
    )
    logger.debug("accepted connection from \(peer.peerName ?? "?")")
    controller._addPeer(peer)
    MOMPeer.start(peer)
  }
}
