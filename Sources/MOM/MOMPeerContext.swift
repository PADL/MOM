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
import Dispatch
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Per-connection peer handle passed to the controller's handler callback.
/// Opaque to callers; used as a cookie to direct replies via `MOMSendReply`.
///
/// Owns the TCP socket fd, the read/write dispatch sources, and the byte
/// buffers used to assemble messages. All mutation happens on the owning
/// `MOMController`'s `queue`.
public final class MOMPeerContext: @unchecked Sendable {
  public internal(set) var peerName: String?

  weak var controller: MOMController?
  var peerAddress: sockaddr_in
  let fd: Int32

  var readSource: DispatchSourceRead?
  var writeSource: DispatchSourceWrite?
  var writeSourceActive = false

  var readBuffer = Data()
  var writeBuffer = Data()
  var bytesWritten = 0
  var lastActivity: time_t = 0
  var closed = false
  var portStatus: MOMPortStatus = .closed // mutated only on `queue`

  init(
    controller: MOMController,
    fd: Int32,
    peerAddress: sockaddr_in,
    peerName: String?
  ) {
    self.controller = controller
    self.fd = fd
    self.peerAddress = peerAddress
    self.peerName = peerName
  }

  deinit {
    // If the peer is dropped without going through MOMPeer.close (e.g. the
    // controller was released), cancel the sources so the read source's
    // cancel handler closes the fd. Suspended sources must resume first.
    if !writeSourceActive, let w = writeSource {
      w.resume()
    }
    writeSource?.cancel()
    readSource?.cancel()
  }

  /// Test-only convenience: a detached peer with no real fd, used by
  /// handler/orchestration tests that don't drive the I/O layer.
  static func detached(
    controller: MOMController,
    peerName: String? = nil
  ) -> MOMPeerContext {
    var sin = sockaddr_in()
    sin.sin_family = sa_family_t(AF_INET)
    return MOMPeerContext(
      controller: controller,
      fd: -1,
      peerAddress: sin,
      peerName: peerName
    )
  }

  var peerPort: UInt16 {
    UInt16(bigEndian: peerAddress.sin_port)
  }
}

/// Peers are reference-identified handles; hash/equate by identity.
extension MOMPeerContext: Hashable {
  public static func == (lhs: MOMPeerContext, rhs: MOMPeerContext) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}
