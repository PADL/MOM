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

final class MOMResolverTests: XCTestCase {
  func testResolveIPv4Literal() {
    let addrs = MOMResolver.resolveIPv4("127.0.0.1")
    XCTAssertEqual(addrs.count, 1)
    XCTAssertEqual(addrs[0], in_addr_t(0x7F000001).bigEndian)
  }

  func testResolveLocalhost() {
    let addrs = MOMResolver.resolveIPv4("localhost")
    // Most environments resolve localhost → 127.0.0.1, but the test must
    // skip in container/CI builds without a resolver.
    try? XCTSkipIf(addrs.isEmpty, "no resolver for 'localhost'")
    XCTAssertTrue(addrs.contains(in_addr_t(0x7F000001).bigEndian))
  }

  func testResolveBogusHost() {
    let addrs = MOMResolver.resolveIPv4("does.not.exist.invalid.xyzzy")
    XCTAssertEqual(addrs, [])
  }

  func testRestrictionAllowsMatchingPeer() {
    var opts = MOMOptions()
    opts.restrictToSpecifiedHost = "127.0.0.1"
    let c = MOMController(options: opts,
                          queue: DispatchQueue(label: "t"),
                          handler: { _, _, _, _, _ in .success })
    var loopback = in_addr()
    inet_pton(AF_INET, "127.0.0.1", &loopback)
    var other = in_addr()
    inet_pton(AF_INET, "192.0.2.1", &other)
    XCTAssertTrue(c.queue.sync { c._peerAddressAllowed(loopback) })
    XCTAssertFalse(c.queue.sync { c._peerAddressAllowed(other) })
  }

  func testNoRestrictionAllowsAnyone() {
    let c = MOMController(options: MOMOptions(),
                          queue: DispatchQueue(label: "t"),
                          handler: { _, _, _, _, _ in .success })
    var any = in_addr()
    inet_pton(AF_INET, "203.0.113.99", &any)
    XCTAssertTrue(c.queue.sync { c._peerAddressAllowed(any) })
  }
}
