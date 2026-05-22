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

/// UDP discovery socket on `MOMPort.discoveryRequest` (10002). Responds to
/// `\n\0NTP Echo` echo requests (echo back to sender) and `?edev\r` discovery
/// requests (multicast/unicast device-info reply on port 10004 with
/// `IP_PKTINFO` source-address pinning).
internal final class MOMDiscovery: @unchecked Sendable {
  static let echoMagic: [UInt8] = [0x0A, 0x00, 0x4E, 0x54, 0x50, 0x20, 0x45, 0x63, 0x68, 0x6F]
  static let discoveryMagic: [UInt8] = [0x3F, 0x65, 0x64, 0x65, 0x76, 0x0D]  // "?edev\r"

  let fd: Int32
  let source: DispatchSourceRead

  static func bind(controller: MOMController) -> MOMDiscovery? {
    let fd = socket(AF_INET, sockType_dgram, 0)
    if fd < 0 { return nil }

    _ = MOMNet.setRecvPktInfo(fd)
    _ = MOMNet.setReusePort(fd)
    _ = MOMNet.setBroadcast(fd)

    guard MOMNet.bind(fd, port: MOMPort.discoveryRequest) else {
      MOMNet.close(fd)
      return nil
    }

    // Non-blocking so recvmsg() / sendmsg() can't stall the dispatch queue.
    MOMNet.makeNonBlocking(fd)

    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: controller.queue)
    let d = MOMDiscovery(fd: fd, source: src)

    src.setEventHandler { [weak controller] in
      guard let c = controller else { return }
      d.readOne(controller: c)
    }
    src.setCancelHandler {
      MOMNet.close(fd)
    }
    src.resume()
    return d
  }

  private init(fd: Int32, source: DispatchSourceRead) {
    self.fd = fd
    self.source = source
  }

  func invalidate() {
    source.cancel()
  }

  // MARK: - Unsolicited announcement

  /// Broadcast an unsolicited discovery notification on every up/running
  /// IPv4 interface (or a single unicast if `unicastTo` is supplied).
  ///
  /// If `options.localInterfaceAddress` is set, only the matching interface
  /// is used. Caller must be on `controller.queue`.
  func announce(controller: MOMController, unicastTo: in_addr_t? = nil) {
    let body = MOMDiscovery.discoveryReplyBytes(controller: controller,
                                                isSolicited: false)
    let restrictLocal = controller._options.localInterfaceAddress?.sin_addr.s_addr

    MOMEnumerateInterfaces { ifp -> MOMStatus in
      guard let sa = ifp.pointee.ifa_addr,
            sa.pointee.sa_family == sa_family_t(AF_INET)
      else { return .continue }

      let ifAddr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_addr
      }
      if let restrict = restrictLocal, ifAddr.s_addr != restrict {
        return .continue
      }

      var pi = in_pktinfo()
      // ipi_ifindex is UInt32 on Darwin, Int32 on Linux/glibc.
      let ifindex = if_nametoindex(ifp.pointee.ifa_name)
      #if canImport(Darwin)
      pi.ipi_ifindex = CUnsignedInt(ifindex)
      #else
      pi.ipi_ifindex = Int32(ifindex)
      #endif
      pi.ipi_spec_dst = ifAddr

      var dst = sockaddr_in()
      #if canImport(Darwin)
      dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      #endif
      dst.sin_family = sa_family_t(AF_INET)
      dst.sin_port = MOMPort.discoveryReply.bigEndian
      dst.sin_addr.s_addr = unicastTo ?? INADDR_BROADCAST.bigEndian

      sendUnicast(Array(body), to: dst, pktInfo: pi)
      return .continue   // keep going across all interfaces
    }
  }

  // MARK: - Receive

  private func readOne(controller: MOMController) {
    var packet = [UInt8](repeating: 0, count: 256)
    var control = [UInt8](repeating: 0, count: 1024)
    var sin = sockaddr_in()

    let (n, pktInfo) = packet.withUnsafeMutableBufferPointer { pktBuf -> (Int, in_pktinfo?) in
      control.withUnsafeMutableBufferPointer { ctlBuf -> (Int, in_pktinfo?) in
        var iov = iovec(iov_base: UnsafeMutableRawPointer(pktBuf.baseAddress!),
                        iov_len: pktBuf.count)
        return withUnsafeMutablePointer(to: &iov) { iovP in
          withUnsafeMutablePointer(to: &sin) { sinP in
            sinP.withMemoryRebound(to: sockaddr.self, capacity: 1) { saP in
              var msg = msghdr()
              msg.msg_name = UnsafeMutableRawPointer(saP)
              msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
              msg.msg_iov = iovP
              msg.msg_iovlen = 1
              msg.msg_control = UnsafeMutableRawPointer(ctlBuf.baseAddress!)
              msg.msg_controllen = .init(ctlBuf.count)
              msg.msg_flags = 0
              let len = recvmsg(fd, &msg, 0)
              if len < 0 { return (0, nil) }
              let ctl = UnsafeRawBufferPointer(start: ctlBuf.baseAddress,
                                               count: Int(msg.msg_controllen))
              return (len, MOMCmsg.firstPktInfo(in: ctl))
            }
          }
        }
      }
    }
    guard n > 0, var pi = pktInfo else { return }
    // Preserve source address for broadcast packets where ipi_spec_dst is 0.
    if pi.ipi_spec_dst.s_addr == 0 {
      pi.ipi_spec_dst.s_addr = sin.sin_addr.s_addr
    }

    let payload = Array(packet.prefix(n))
    let senderSin = sin
    if Self.startsWith(payload, Self.echoMagic) {
      // Echo back to sender
      sendUnicast(payload, to: senderSin, pktInfo: pi)
    } else if Self.startsWith(payload, Self.discoveryMagic) {
      respondToDiscovery(controller: controller, requestPktInfo: pi, sourceSin: senderSin)
    }
  }

  private static func startsWith(_ data: [UInt8], _ prefix: [UInt8]) -> Bool {
    guard data.count >= prefix.count else { return false }
    for i in 0..<prefix.count where data[i] != prefix[i] { return false }
    return true
  }

  // MARK: - Discovery reply

  /// Build the device-info `:edev,...` payload from the controller's options.
  static func discoveryReplyBytes(controller: MOMController, isSolicited: Bool) -> Data {
    let o = controller._options
    let type: MOMEvent = isSolicited ? .typeDeviceReply : .typeDeviceNotification
    let params: [MOMParam] = [
      .string(o.serialNumber),
      .int(0),
      .string(o.modelID),
      .string(o.deviceName),
      .int(o.deviceID),
      .int(1),
      .int(Int32(MOMStatus.success.rawValue)),
    ]
    return MOMMessage.encode(.enumerateDevices | type, params: params) ?? Data()
  }

  private func respondToDiscovery(controller: MOMController,
                                  requestPktInfo: in_pktinfo,
                                  sourceSin: sockaddr_in) {
    let local = controller._options.localInterfaceAddress
    // If a specific local interface is configured, only reply when it matches
    // the destination the request was addressed to (ipi_spec_dst).
    if let local = local {
      if local.sin_addr.s_addr != requestPktInfo.ipi_spec_dst.s_addr { return }
    }

    var replyAddr = sockaddr_in()
    #if canImport(Darwin)
    replyAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    replyAddr.sin_family = sa_family_t(AF_INET)
    replyAddr.sin_port = MOMPort.discoveryReply.bigEndian
    replyAddr.sin_addr.s_addr = sourceSin.sin_addr.s_addr

    let body = MOMDiscovery.discoveryReplyBytes(controller: controller, isSolicited: true)
    sendUnicast(Array(body), to: replyAddr, pktInfo: requestPktInfo)
  }

  // MARK: - Send

  /// `sendmsg(fd, ...)` with the given destination and IP_PKTINFO ancillary
  /// data so the source IP can be pinned to a specific interface.
  @discardableResult
  private func sendUnicast(_ data: [UInt8],
                           to peer: sockaddr_in,
                           pktInfo: in_pktinfo) -> Bool {
    var dst = peer
    var ctl = [UInt8](repeating: 0, count: MOMCmsg.space(MemoryLayout<in_pktinfo>.size))

    return data.withUnsafeBufferPointer { dataBuf -> Bool in
      ctl.withUnsafeMutableBufferPointer { ctlBuf -> Bool in
        let written = MOMCmsg.writePktInfo(
          pktInfo,
          into: UnsafeMutableRawBufferPointer(ctlBuf))
        if written == 0 { return false }

        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: dataBuf.baseAddress!),
                        iov_len: dataBuf.count)
        return withUnsafeMutablePointer(to: &iov) { iovP -> Bool in
          withUnsafeMutablePointer(to: &dst) { sinP -> Bool in
            sinP.withMemoryRebound(to: sockaddr.self, capacity: 1) { saP -> Bool in
              var msg = msghdr()
              msg.msg_name = UnsafeMutableRawPointer(saP)
              msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
              msg.msg_iov = iovP
              msg.msg_iovlen = 1
              msg.msg_control = UnsafeMutableRawPointer(ctlBuf.baseAddress!)
              msg.msg_controllen = .init(written)
              msg.msg_flags = 0
              return sendmsg(fd, &msg, 0) >= 0
            }
          }
        }
      }
    }
  }
}

// SOCK_DGRAM is an Int32 on Darwin and a CInt enum elsewhere; alias it.
#if canImport(Darwin)
private let sockType_dgram: Int32 = SOCK_DGRAM
#else
private let sockType_dgram: Int32 = Int32(SOCK_DGRAM.rawValue)
#endif
