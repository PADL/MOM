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

/// Per-connection peer handle passed to the controller's handler callback.
/// Opaque to callers; used as a cookie to direct replies via `MOMSendReply`.
///
/// Owns the TCP socket fd, the read/write dispatch sources, and the byte
/// buffers used to assemble messages. All mutation happens on the owning
/// `MOMController`'s `queue`.
public final class MOMPeerContext: @unchecked Sendable {
  public internal(set) var peerName: String?

  internal weak var controller: MOMController?
  internal var peerAddress: sockaddr_in
  internal let fd: Int32

  internal var readSource:  DispatchSourceRead?
  internal var writeSource: DispatchSourceWrite?
  internal var writeSourceActive = false

  internal var readBuffer  = Data()
  internal var writeBuffer = Data()
  internal var bytesWritten = 0
  internal var lastActivity: time_t = 0
  internal var closed = false

  internal init(controller: MOMController,
                fd: Int32,
                peerAddress: sockaddr_in,
                peerName: String?) {
    self.controller = controller
    self.fd = fd
    self.peerAddress = peerAddress
    self.peerName = peerName
  }

  /// Test-only convenience: a detached peer with no real fd, used by
  /// handler/orchestration tests that don't drive the I/O layer.
  internal static func detached(controller: MOMController,
                                peerName: String? = nil) -> MOMPeerContext {
    var sin = sockaddr_in()
    sin.sin_family = sa_family_t(AF_INET)
    return MOMPeerContext(controller: controller, fd: -1,
                          peerAddress: sin, peerName: peerName)
  }

  internal var peerPort: UInt16 {
    UInt16(bigEndian: peerAddress.sin_port)
  }
}
