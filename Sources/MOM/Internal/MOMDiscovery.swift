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

/// UDP discovery socket on `MOMPort.discoveryRequest` (10002). Responds to
/// `\n\0NTP Echo` echo requests (echo back to sender) and `?edev\r` discovery
/// requests (reply on port 10004 from the address the request was sent to).
///
/// Like the hardware MOM, solicited discovery replies are *broadcast* unless
/// a host restriction is configured, in which case they are unicast to the
/// requester — and requests from hosts outside the restriction are dropped.
final class MOMDiscovery: @unchecked Sendable {
  static let echoMagic: [UInt8] = [0x0A, 0x00, 0x4E, 0x54, 0x50, 0x20, 0x45, 0x63, 0x68, 0x6F]
  static let discoveryMagic: [UInt8] =
    [MOMMessage.tagByte(for: .typeHostGetRequest)] + Array("edev".utf8)
      + [MOMMessage.recordTerminator] // "?edev\r"

  let fd: Socket.SocketDescriptor
  let source: IOReadinessSource

  static func bind(controller: MOMController) -> MOMDiscovery? {
    guard let sock = Socket.udp() else { return nil }
    sock.setRecvPktInfo()
    sock.setReusePort()
    sock.setBroadcast()

    guard sock.bind(port: MOMPort.discoveryRequest.rawValue) else { return nil }
    // ^ sock deinit closes the fd on failure

    // Non-blocking so recvmsg() / sendmsg() can't stall the dispatch queue.
    sock.makeNonBlocking()

    let fd = sock.detach()
    let src = IOReadinessSource.read(fd: fd, queue: controller.queue)
    let d = MOMDiscovery(fd: fd, source: src)

    src.setEventHandler { [weak d, weak controller] in
      guard let d, let c = controller else { return }
      d.readOne(controller: c)
    }
    src.setCancelHandler {
      Socket.close(fd)
    }
    src.resume()
    controller.logger.debug("listening on UDP discovery port \(MOMPort.discoveryRequest.rawValue)")
    return d
  }

  private init(fd: Socket.SocketDescriptor, source: IOReadinessSource) {
    self.fd = fd
    self.source = source
  }

  func invalidate() {
    source.cancel()
    closeSendSockets()
  }

  deinit {
    // Dropping the discovery object without invalidate() must still close
    // the fd; the source owns it via the cancel handler.
    if !source.isCancelled {
      source.cancel()
    }
    closeSendSockets()
  }

  // MARK: - Sending from a specific source address

  /// Send sockets bound to a source address, keyed by it. Confined to
  /// `controller.queue` like all sends. Bounded by the host's addresses and
  /// torn down with the discovery object, which is recreated on every
  /// discoverability cycle — so a network change naturally drops sockets
  /// bound to vanished addresses.
  private var sendSockets: [in_addr_t: Socket.SocketDescriptor] = [:]

  private func closeSendSockets() {
    for fd in sendSockets.values {
      Socket.close(fd)
    }
    sendSockets.removeAll()
  }

  /// The send socket bound to `source`, creating it on first use.
  private func sendSocket(
    boundTo source: in_addr,
    controller: MOMController
  ) -> Socket.SocketDescriptor? {
    if let fd = sendSockets[source.s_addr] { return fd }
    guard let sock = Socket.udp() else { return nil }
    sock.setBroadcast()
    guard sock.bind(port: 0, address: source.s_addr) else {
      controller.logger
        .debug("failed to bind discovery send socket to \(Socket.format(source))")
      return nil
    }
    let fd = sock.detach()
    sendSockets[source.s_addr] = fd
    return fd
  }

  /// Send `body` to `dst` with `source` as the datagram's source address,
  /// from a socket bound to it (C parity:
  /// `sendDiscoveryReplyOnInterface`). Binding is what actually sets the
  /// source — Darwin honors `ipi_spec_dst` only on a bound socket (unbound,
  /// `sendmsg` fails unless an interface is selected via `ipi_ifindex`, and
  /// then the kernel stamps that interface's *primary* address — wrong for
  /// controllers bound to an interface alias), and Windows' `IN_PKTINFO`
  /// has no spec_dst field at all.
  private func send(
    _ body: [UInt8],
    from source: in_addr,
    to dst: sockaddr_in,
    controller: MOMController
  ) {
    guard let sendFD = sendSocket(boundTo: source, controller: controller) else { return }
    let pi = Socket.pktInfo(interfaceIndex: 0, specDst: source)
    if !Socket.send(body, on: sendFD, to: dst, pktInfo: pi) {
      // The bound address may have gone away mid-cycle; rebind on next use.
      Socket.close(sendFD)
      sendSockets.removeValue(forKey: source.s_addr)
    }
  }

  // MARK: - Unsolicited announcement

  /// Broadcast an unsolicited discovery notification on every up/running
  /// IPv4 interface (or a single unicast if `unicastTo` is supplied).
  ///
  /// If `controller.localInterfaceAddress` is set, only the matching interface
  /// is used. Caller must be on `controller.queue`.
  func announce(controller: MOMController, unicastTo: in_addr_t? = nil) {
    let body = Array(MOMDiscovery.discoveryReplyBytes(
      controller: controller,
      isSolicited: false
    ))
    let restrictLocal = controller._localInterfaceAddress?.sin_addr.s_addr

    MOMEnumerateInterfaces { interface -> MOMStatus in
      if let restrict = restrictLocal, interface.address.s_addr != restrict {
        return .continue
      }

      let dst = Socket.ipv4Address(
        port: MOMPort.discoveryReply.rawValue,
        address: unicastTo ?? INADDR_BROADCAST.bigEndian
      )
      let kind = unicastTo == nil ? "broadcast" : "unicast"
      controller.logger
        .debug(
          "sending \(kind) discovery notification message from \(interface.addressString) to \(Socket.format(dst.sin_addr)):\(MOMPort.discoveryReply.rawValue) (via \(interface.name))"
        )
      self.send(body, from: interface.address, to: dst, controller: controller)
      return .continue // keep going across all interfaces
    }
  }

  // MARK: - Receive

  private func readOne(controller: MOMController) {
    guard let (payload, senderAddress, pktInfo) = Socket.receive(on: fd, capacity: 256),
          var pi = pktInfo
    else { return }

    // Preserve source address for broadcast packets where ipi_spec_dst is 0.
    if pi.ipi_spec_dst.s_addr == 0 {
      pi.ipi_spec_dst.s_addr = senderAddress.sin_addr.s_addr
    }

    if payload.starts(with: Self.echoMagic) {
      // Echo back to sender
      Socket.send(payload, on: fd, to: senderAddress, pktInfo: pi)
    } else if payload.starts(with: Self.discoveryMagic) {
      controller.logger.debug("discovery request from \(Socket.format(senderAddress.sin_addr))")
      respondToDiscovery(controller: controller, requestPktInfo: pi, sourceAddress: senderAddress)
    }
  }

  // MARK: - Discovery reply

  /// Build the device-info `:edev,...` payload from the controller's options.
  static func discoveryReplyBytes(controller: MOMController, isSolicited: Bool) -> Data {
    let o = controller._options
    let type: MOMEvent = isSolicited ? .typeDeviceReply : .typeDeviceNotification
    // Wire order per the hardware MOM: status,1,deviceID,name,model,0,serial
    let params: [MOMParameter] = [
      .int(Int32(MOMStatus.success.rawValue)),
      .int(1),
      .int(o.deviceID),
      .string(o.deviceName),
      .string(o.modelID),
      .int(0),
      .string(o.serialNumber),
    ]
    let message = MOMMessage.encode(.enumerateDevices | type, params: params) ?? Data()
    controller.logger
      .debug(
        "created discovery \(isSolicited ? "reply" : "notification") message \(wireDescription(message))"
      )
    return message
  }

  private func respondToDiscovery(
    controller: MOMController,
    requestPktInfo: in_pktinfo,
    sourceAddress: sockaddr_in
  ) {
    // If a specific local interface is configured, only reply when it matches
    // the destination the request was addressed to (ipi_spec_dst).
    if let local = controller._localInterfaceAddress,
       local.sin_addr.s_addr != requestPktInfo.ipi_spec_dst.s_addr
    {
      return
    }

    // Host restriction: ignore requests from non-allowed hosts entirely.
    // Replies are broadcast (hardware-MOM behavior) unless restricted, in
    // which case they are unicast to the requester.
    let replyTarget: in_addr_t
    if controller._options.restrictToSpecifiedHost != nil {
      guard controller._peerAddressAllowed(sourceAddress.sin_addr) else {
        controller.logger
          .debug(
            "ignoring discovery request from \(Socket.format(sourceAddress.sin_addr)) (host restriction)"
          )
        return
      }
      replyTarget = sourceAddress.sin_addr.s_addr
    } else {
      replyTarget = INADDR_BROADCAST.bigEndian
    }

    let replyAddr = Socket.ipv4Address(
      port: MOMPort.discoveryReply.rawValue,
      address: replyTarget
    )
    let body = MOMDiscovery.discoveryReplyBytes(controller: controller, isSolicited: true)

    // Reply with the address the request was addressed to as the source,
    // provided it is one of ours (C parity: the reply path enumerated
    // interfaces and bound the matching one). A spec_dst that matches no
    // interface — a broadcast arrival whose spec_dst was substituted with
    // the sender — falls back to the shared socket without a specific source address.
    var source: in_addr?
    MOMEnumerateInterfaces { interface -> MOMStatus in
      guard interface.address.s_addr == requestPktInfo.ipi_spec_dst.s_addr else {
        return .continue
      }
      source = interface.address
      return .success
    }

    let kind = replyTarget == INADDR_BROADCAST.bigEndian ? "broadcast" : "unicast"
    controller.logger
      .debug(
        "sending \(kind) discovery reply message from \(source.map(Socket.format) ?? "?") to \(Socket.format(replyAddr.sin_addr)):\(MOMPort.discoveryReply.rawValue)"
      )

    if let source {
      send(Array(body), from: source, to: replyAddr, controller: controller)
    } else {
      Socket.send(Array(body), on: fd, to: replyAddr, pktInfo: requestPktInfo)
    }
  }
}
