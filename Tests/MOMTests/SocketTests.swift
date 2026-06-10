//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import XCTest
@testable import MOM

/// True if `fd` refers to an open socket. POSIX answers via fcntl; Windows
/// SOCKETs are not CRT fds, so probe with a benign getsockopt instead.
private func isLiveSocket(_ fd: Socket.SocketDescriptor) -> Bool {
  #if canImport(WinSDK)
  var type: Int32 = 0
  var len = socklen_t(MemoryLayout<Int32>.size)
  return withUnsafeMutablePointer(to: &type) { p in
    p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) { cp in
      getsockopt(fd, SOL_SOCKET, SO_TYPE, cp, &len) == 0
    }
  }
  #else
  return fcntl(fd, F_GETFD) >= 0
  #endif
}

final class SocketTests: XCTestCase {
  // MARK: - Ownership

  func testDroppingSocketClosesFD() {
    var fd = Socket.invalidDescriptor
    if let sock = Socket.udp() {
      fd = sock.fd
      XCTAssertTrue(isLiveSocket(fd))
    } // sock deinit runs here
    XCTAssertFalse(isLiveSocket(fd))
    // The module's `errno` shadow can't be named here (the MOM enum shadows
    // the module name), so use the platform spellings directly.
    #if canImport(WinSDK)
    XCTAssertEqual(WSAGetLastError(), WSAENOTSOCK)
    #elseif canImport(Darwin)
    XCTAssertEqual(Darwin.errno, EBADF)
    #else
    XCTAssertEqual(Glibc.errno, EBADF)
    #endif
  }

  func testDetachTransfersOwnershipWithoutClosing() {
    guard let sock = Socket.udp() else { return XCTFail("socket()") }
    let fd = sock.detach()
    XCTAssertTrue(isLiveSocket(fd), "fd must survive detach()")
    Socket.close(fd)
    XCTAssertFalse(isLiveSocket(fd))
  }

  // MARK: - Factories

  func testIPv4AddressFactory() {
    let sin = Socket.ipv4Address(port: 10004, address: INADDR_BROADCAST.bigEndian)
    XCTAssertEqual(sin.sin_family, sa_family_t(AF_INET))
    XCTAssertEqual(sin.sin_port, UInt16(10004).bigEndian)
    XCTAssertEqual(sin.sin_addr.s_addr, INADDR_BROADCAST.bigEndian)
    #if canImport(Darwin)
    XCTAssertEqual(sin.sin_len, UInt8(MemoryLayout<sockaddr_in>.size))
    #endif
  }

  func testPktInfoFactory() {
    var dst = in_addr()
    dst.s_addr = 0x0100007F  // 127.0.0.1 in network order on LE
    let pi = Socket.pktInfo(interfaceIndex: 7, specDst: dst)
    XCTAssertEqual(UInt32(pi.ipi_ifindex), 7)
    XCTAssertEqual(pi.ipi_spec_dst.s_addr, dst.s_addr)
  }

  func testFormatIPv4() {
    var addr = in_addr()
    inet_pton(AF_INET, "192.0.2.42", &addr)
    XCTAssertEqual(Socket.format(addr), "192.0.2.42")
  }

  // MARK: - Cmsg pack/unpack

  func testCmsgPktInfoRoundTrip() {
    var dst = in_addr()
    inet_pton(AF_INET, "10.0.7.10", &dst)
    let original = Socket.pktInfo(interfaceIndex: 3, specDst: dst)

    var buf = [UInt8](repeating: 0, count: Cmsg.space(MemoryLayout<in_pktinfo>.size))
    let written = buf.withUnsafeMutableBytes { Cmsg.writePktInfo(original, into: $0) }
    XCTAssertEqual(written, buf.count)

    let decoded = buf.withUnsafeBytes { Cmsg.firstPktInfo(in: $0) }
    XCTAssertNotNil(decoded)
    XCTAssertEqual(decoded?.ipi_spec_dst.s_addr, dst.s_addr)
    XCTAssertEqual(decoded.map { UInt32($0.ipi_ifindex) }, 3)
  }

  func testCmsgWriteRejectsUndersizedBuffer() {
    var buf = [UInt8](repeating: 0, count: Cmsg.space(MemoryLayout<in_pktinfo>.size) - 1)
    let written = buf.withUnsafeMutableBytes {
      Cmsg.writePktInfo(in_pktinfo(), into: $0)
    }
    XCTAssertEqual(written, 0)
  }

  func testCmsgSkipsForeignControlMessages() {
    // [SOL_SOCKET cmsg with 4-byte payload][IP_PKTINFO cmsg]
    let foreignSpace = Cmsg.space(4)
    let pktInfoSpace = Cmsg.space(MemoryLayout<in_pktinfo>.size)
    var buf = [UInt8](repeating: 0, count: foreignSpace + pktInfoSpace)

    var dst = in_addr()
    inet_pton(AF_INET, "10.0.7.11", &dst)
    let pi = Socket.pktInfo(interfaceIndex: 9, specDst: dst)

    buf.withUnsafeMutableBytes { raw in
      var foreign = cmsghdr()
      foreign.cmsg_len = .init(Cmsg.length(4))
      foreign.cmsg_level = SOL_SOCKET
      foreign.cmsg_type = 0
      raw.baseAddress!.storeBytes(of: foreign, as: cmsghdr.self)

      let rest = UnsafeMutableRawBufferPointer(rebasing: raw[foreignSpace...])
      XCTAssertEqual(Cmsg.writePktInfo(pi, into: rest), pktInfoSpace)
    }

    let decoded = buf.withUnsafeBytes { Cmsg.firstPktInfo(in: $0) }
    XCTAssertEqual(decoded?.ipi_spec_dst.s_addr, dst.s_addr)
  }

  func testCmsgIgnoresTruncatedHeader() {
    let buf = [UInt8](repeating: 0xFF, count: MemoryLayout<cmsghdr>.size - 1)
    let decoded = buf.withUnsafeBytes { Cmsg.firstPktInfo(in: $0) }
    XCTAssertNil(decoded)
  }

  // MARK: - Loopback datagram I/O (exercises the msghdr plumbing end to end)

  func testSendReceiveWithPktInfoOverLoopback() throws {
    guard let rx = Socket.udp(), let tx = Socket.udp() else {
      return XCTFail("socket()")
    }
    rx.setRecvPktInfo()
    XCTAssertTrue(rx.bind(port: 0, address: INADDR_LOOPBACK.bigEndian))
    rx.makeNonBlocking()

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { sp in
      sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        getsockname(rx.fd, sa, &len)
      }
    }

    let payload: [UInt8] = Array("?edev\r".utf8)
    let dst = Socket.ipv4Address(port: UInt16(bigEndian: bound.sin_port),
                                 address: INADDR_LOOPBACK.bigEndian)
    XCTAssertTrue(Socket.send(payload, on: tx.fd, to: dst))

    // Non-blocking receiver: poll briefly for delivery.
    var result: (payload: [UInt8], from: sockaddr_in, pktInfo: in_pktinfo?)?
    for _ in 0..<100 {
      result = Socket.receive(on: rx.fd, capacity: 64)
      if result != nil { break }
      Thread.sleep(forTimeInterval: 0.01)
    }

    let received = try XCTUnwrap(result)
    XCTAssertEqual(received.payload, payload)
    XCTAssertEqual(received.from.sin_addr.s_addr, INADDR_LOOPBACK.bigEndian)
    let pi = try XCTUnwrap(received.pktInfo, "IP_PKTINFO requested but not delivered")
    XCTAssertEqual(pi.ipi_spec_dst.s_addr == INADDR_LOOPBACK.bigEndian
                     || pi.ipi_addr.s_addr == INADDR_LOOPBACK.bigEndian, true)
  }
}
