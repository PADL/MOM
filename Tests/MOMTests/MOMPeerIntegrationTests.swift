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
import Foundation
import XCTest
@testable import MOM

final class MOMPeerIntegrationTests: XCTestCase {
  /// Bind the listener on an ephemeral port (we override the control port
  /// via a helper) so the test doesn't collide with system services.
  private func bindEphemeralListener(controller: MOMController) -> MOMListener {
    let listener = MOMListener.bind(on: 0,                       // 0 = ephemeral
                                    address: INADDR_ANY,
                                    controller: controller)!
    controller.queue.sync { controller._tcpListener = listener }
    return listener
  }

  /// Read the port the kernel assigned to a listening socket.
  private static func boundPort(_ fd: Int32) -> UInt16 {
    var sin = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &sin) { sp in
      sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        getsockname(fd, sa, &len)
      }
    }
    return UInt16(bigEndian: sin.sin_port)
  }

  /// Open a blocking TCP client to 127.0.0.1:<port>.
  private static func dial(port: UInt16) -> Int32? {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return nil }
    var sin = sockaddr_in()
    #if canImport(Darwin)
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &sin.sin_addr)
    let ok = withUnsafePointer(to: &sin) { sp in
      sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    if !ok { close(fd); return nil }
    return fd
  }

  func testTCPRoundTripGetDeviceID() throws {
    let q = DispatchQueue(label: "test.controller")
    var opts = MOMOptions(); opts.deviceID = 42; opts.deviceName = "MOMTest"
    let appCalled = expectation(description: "app handler"); appCalled.isInverted = true
    let controller = MOMController(options: opts, queue: q,
                                   handler: { _, _, _, _, _ in
                                     appCalled.fulfill()
                                     return .success
                                   })

    let listener = bindEphemeralListener(controller: controller)
    let port = Self.boundPort(listener.fd)
    XCTAssertGreaterThan(port, 0)

    let client = Self.dial(port: port)
    XCTAssertNotNil(client)
    defer { close(client!) }

    // Send a GetDeviceID request.
    let req = Data("?gdevid\r".utf8)
    let sent = req.withUnsafeBytes { write(client!, $0.baseAddress, $0.count) }
    XCTAssertEqual(sent, req.count)

    // Read the reply.
    var buf = [UInt8](repeating: 0, count: 256)
    let got = buf.withUnsafeMutableBufferPointer { read(client!, $0.baseAddress, $0.count) }
    XCTAssertGreaterThan(got, 0)
    let reply = Data(buf.prefix(Int(got)))
    XCTAssertEqual(reply, Data(":gdevid,0,42,'MOMTest'\r".utf8))

    wait(for: [appCalled], timeout: 0.1)

    _ = controller.endDiscoverability()
  }

  func testTCPMultipleMessagesInOneRead() throws {
    let q = DispatchQueue(label: "test.controller")
    var opts = MOMOptions(); opts.deviceID = 1; opts.deviceName = "X"
    let controller = MOMController(options: opts, queue: q,
                                   handler: { _, _, _, _, _ in .success })

    let listener = bindEphemeralListener(controller: controller)
    let client = Self.dial(port: Self.boundPort(listener.fd))!
    defer { close(client) }

    let payload = Data("?gdevid\r?galivetime\r".utf8)
    _ = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }

    // Both replies should be sent. Read until we have at least 2 \r terminators.
    var reply = Data()
    let deadline = Date().addingTimeInterval(1.0)
    while reply.filter({ $0 == 0x0D }).count < 2, Date() < deadline {
      var b = [UInt8](repeating: 0, count: 256)
      let n = b.withUnsafeMutableBufferPointer { read(client, $0.baseAddress, $0.count) }
      if n > 0 { reply.append(b, count: Int(n)) }
      else if n < 0 { break }
    }
    XCTAssertTrue(reply.contains(Data(":gdevid,0,1,'X'\r".utf8).first!))
    XCTAssertTrue(reply.range(of: Data(":galivetime,0,20\r".utf8)) != nil)

    _ = controller.endDiscoverability()
  }
}
