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

final class MOMControllerTests: XCTestCase {
  // MARK: - notify / sendDeferred fan-out

  func testNotifyFansOutToEveryPeer() {
    let q = DispatchQueue(label: "test")
    let c = MOMController(options: MOMOptions(), queue: q,
                          handler: { _, _, _, _, _ in .success })
    var sent: [(MOMPeerContext, Data)] = []
    c._sendHook = { p, d in sent.append((p, d)) }

    let p1 = MOMPeerContext.detached(controller: c, peerName: "a")
    let p2 = MOMPeerContext.detached(controller: c, peerName: "b")
    q.sync {
      c._addPeer(p1)
      c._addPeer(p2)
    }

    let s = c.notify(.setKeyState, params: [.int(1), .int(0)])
    XCTAssertEqual(s, .success)
    XCTAssertEqual(sent.count, 2)
    XCTAssertEqual(sent[0].1, Data("!skeystate,1,0\r".utf8))
    XCTAssertEqual(sent[1].1, Data("!skeystate,1,0\r".utf8))
  }

  func testNotifyWithNoPeersReturnsSocketError() {
    let q = DispatchQueue(label: "test")
    let c = MOMController(queue: q, handler: { _, _, _, _, _ in .success })
    XCTAssertEqual(c.notify(.setKeyState, params: [.int(1)]), .socketError)
  }

  // MARK: - Alive-time expiry

  func testExpireStalePeersDropsIdlePeers() {
    let q = DispatchQueue(label: "test")
    let c = MOMController(queue: q, handler: { _, _, _, _, _ in .success })
    let live = MOMPeerContext.detached(controller: c, peerName: "live")
    let dead = MOMPeerContext.detached(controller: c, peerName: "dead")

    q.sync {
      c._setAliveTime(5)
      live.lastActivity = time(nil)        // fresh
      dead.lastActivity = time(nil) - 60   // ancient
      c._addPeer(live)
      c._addPeer(dead)
      c._expireStalePeers()
    }

    XCTAssertEqual(q.sync { c._peers.map { $0.peerName } }, ["live"])
  }

  func testSetAliveTimeRejectsOutOfRange() {
    let q = DispatchQueue(label: "test")
    let c = MOMController(queue: q, handler: { _, _, _, _, _ in .success })
    let accepted = q.sync { c._setAliveTime(0) }
    XCTAssertFalse(accepted)
  }

  // MARK: - Interface enumeration

  func testEnumerateInterfacesYieldsAtLeastOne() {
    var count = 0
    let s = MOMEnumerateInterfaces { _ in
      count += 1
      return .continue
    }
    // .continue returned at end leaves status as the default (.socketError)
    // when nothing was hit. In a CI environment with at least one up IPv4
    // interface we expect count > 0; if not (e.g. no networking) skip.
    if count == 0 {
      try? XCTSkipIf(true, "no up IPv4 interfaces present")
    }
    XCTAssertGreaterThanOrEqual(count, 1)
    _ = s   // status sentinel — value depends on environment
  }
}
