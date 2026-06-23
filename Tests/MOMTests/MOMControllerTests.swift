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

final class MOMControllerTests: XCTestCase {
  // MARK: - notify fan-out

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
      live.lastActivity = Date()                          // fresh
      dead.lastActivity = Date(timeIntervalSinceNow: -60) // ancient
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

  // MARK: - Handler re-entrancy

  /// The C API allowed handlers to call MOMControllerNotify/GetOptions
  /// directly; the Swift port must not deadlock when a handler running on
  /// the controller's queue calls back into the public API.
  func testHandlerCanReenterControllerAPIs() {
    let q = DispatchQueue(label: "test")
    var observedID: Int32 = -1
    var notifyStatus: MOMStatus = .continue
    var opts = MOMOptions(); opts.deviceID = 9
    let c = MOMController(options: opts, queue: q, handler: { c, _, _, _, _ in
      observedID = c.options.deviceID                          // re-entrant read
      c.updateOptions { $0.deviceName = "reentered" }          // re-entrant write
      notifyStatus = c.notify(.setKeyState, params: [.int(1), .int(1)])
      return .success
    })
    var sent: [Data] = []
    c._sendHook = { _, d in sent.append(d) }
    let p = MOMPeerContext.detached(controller: c, peerName: "p")
    q.sync {
      c._addPeer(p)
      c._setMasterPeer(p)
      _ = c._processEvent(peer: p,
                          eventWithType: .setLedState | .typeHostNotification,
                          params: [.int(1), .int(0)])
    }
    XCTAssertEqual(observedID, 9)
    XCTAssertEqual(notifyStatus, .success)
    XCTAssertEqual(c.options.deviceName, "reentered")
    XCTAssertEqual(sent.last, Data("!skeystate,1,1\r".utf8))
  }

  // MARK: - Port-status events

  /// C parity: `_MOMSetPeerPortStatus` always notified the application
  /// handler. Clients (e.g. MOMOCABridge) derive their connection state from
  /// these events — without them, OCA-side writes are rejected forever.
  func testPortStatusTransitionsReachAppHandler() {
    let q = DispatchQueue(label: "test")
    var portEvents: [MOMEvent] = []
    let c = MOMController(queue: q, handler: { _, _, evt, _, _ in
      if evt.event.rawValue >= MOMEvent.portError.rawValue,
         evt.event.rawValue <= MOMEvent.portConnected.rawValue {
        portEvents.append(evt.event)
      }
      return .success
    })
    let p = MOMPeerContext.detached(controller: c, peerName: "p")
    q.sync {
      c._addPeer(p)
      c._setPeerPortStatus(p, .open)
      // DADman takes mastership -> .connected must reach the handler
      _ = c._processEvent(peer: p,
                          eventWithType: .setMaster | .typeHostNotification,
                          params: [.int(1)])
      // and releases it -> .ready
      _ = c._processEvent(peer: p,
                          eventWithType: .setMaster | .typeHostNotification,
                          params: [.int(0)])
    }
    XCTAssertEqual(portEvents, [.portOpen, .portConnected, .portReady])
  }

  // MARK: - Expiry timer

  /// C parity: the peer-expiry timer is armed from creation, so a peer that
  /// connects and dies without ever sending salivetime still expires.
  func testExpiryTimerArmedAtInit() {
    let q = DispatchQueue(label: "test")
    let c = MOMController(queue: q, handler: { _, _, _, _, _ in .success })
    XCTAssertNotNil(q.sync { c._expiryTimer })
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

  // MARK: - Interface restriction

  private func makeController(
    restrictTo uuids: [String]? = nil
  ) -> (DispatchQueue, MOMController) {
    var options = MOMOptions()
    options.restrictToInterfaceUUIDs = uuids
    let q = DispatchQueue(label: "test")
    let c = MOMController(options: options, queue: q, handler: { _, _, _, _, _ in .success })
    return (q, c)
  }

  func testInterfaceRestrictionInactiveByDefault() {
    let (q, c) = makeController()
    q.sync {
      XCTAssertFalse(c._interfaceRestrictionActive)
      // With no restriction, an unidentifiable arrival interface still passes.
      XCTAssertTrue(c._interfaceRestrictionPermits(nil))
    }
  }

  func testInterfaceRestrictionFailsClosedOnUnknownInterface() {
    let (q, c) = makeController(restrictTo: [UUID().uuidString])
    q.sync {
      XCTAssertTrue(c._interfaceRestrictionActive)
      // Active restriction + unresolved arrival interface ⇒ denied.
      XCTAssertFalse(c._interfaceRestrictionPermits(nil))
    }
  }

  func testInterfaceRestrictionPermitsAllowedAndDeniesOthers() {
    // Build the allow-list from a real interface that has a physicalUUID, so
    // there is something concrete to match. Skip where the platform exposes
    // none (Linux, or a Darwin/Windows host with no service/adapter identity).
    var withUUID: MOMInterface?
    MOMEnumerateInterfaces { iface in
      if iface.physicalUUID != nil { withUUID = iface; return .success }
      return .continue
    }
    guard let allowed = withUUID, let allowedUUID = allowed.physicalUUID else {
      try? XCTSkipIf(true, "no interface with a physicalUUID present")
      return
    }

    let (q, c) = makeController(restrictTo: [allowedUUID.uuidString])
    q.sync {
      XCTAssertTrue(c._interfaceAllowed(allowed))
      XCTAssertTrue(c._interfaceRestrictionPermits(allowed))

      // A synthesized arrival pktinfo for the allowed address resolves back to
      // a permitted interface.
      let pi = Socket.pktInfo(interfaceIndex: 0, specDst: allowed.address)
      XCTAssertTrue(c._interfaceRestrictionPermits(c._arrivalInterface(for: pi)))
    }

    // A restriction naming only an unrelated UUID denies the same interface.
    let (q2, c2) = makeController(restrictTo: [UUID().uuidString])
    q2.sync {
      XCTAssertFalse(c2._interfaceAllowed(allowed))
      XCTAssertFalse(c2._interfaceRestrictionPermits(allowed))
    }
  }

  func testShouldRespondHonorsLocalInterfaceHardBind() {
    let (q, c) = makeController()

    let bound = Socket.ipv4Address(port: 0, address: 0x0100_000A)   // 10.0.0.1
    let other = in_addr(s_addr: 0x0200_000A)                        // 10.0.0.2

    q.sync {
      // No hard bind, no restriction: respond regardless of arrival interface.
      XCTAssertTrue(c._shouldRespondOnArrival(Socket.pktInfo(interfaceIndex: 0, specDst: other)))

      // Hard bind: respond only to datagrams addressed to the bound address.
      c._localInterfaceAddress = bound
      XCTAssertTrue(c._shouldRespondOnArrival(Socket.pktInfo(interfaceIndex: 0, specDst: bound.sin_addr)))
      XCTAssertFalse(c._shouldRespondOnArrival(Socket.pktInfo(interfaceIndex: 0, specDst: other)))
    }
  }

  func testHardBindOverridesStaleUUIDRestriction() {
    // A hard bind is authoritative: a leftover UUID allow-list (which doesn't
    // name the bound interface) must not also filter, or it would block the
    // very interface the caller bound to.
    let (q, c) = makeController(restrictTo: [UUID().uuidString])
    let bound = Socket.ipv4Address(port: 0, address: 0x0100_000A)
    q.sync {
      XCTAssertTrue(c._interfaceRestrictionActive)        // INADDR_ANY: filter applies
      c._localInterfaceAddress = bound
      XCTAssertFalse(c._interfaceRestrictionActive)       // hard bind: filter inert
      XCTAssertTrue(c._shouldRespondOnArrival(Socket.pktInfo(interfaceIndex: 0, specDst: bound.sin_addr)))
    }
  }
}
