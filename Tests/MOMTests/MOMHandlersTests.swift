//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
//

import XCTest
@testable import MOM

final class MOMHandlersTests: XCTestCase {
  /// Helper: build a controller plus a stub peer, set as master so requests
  /// aren't rejected, and capture any messages the orchestrator enqueues.
  private struct Harness {
    let controller: MOMController
    let peer: MOMPeerContext
    let sent: () -> [(MOMPeerContext, Data)]
  }

  private func makeHarness(
    options: MOMOptions = MOMOptions(),
    asMaster: Bool = true,
    appHandler: @escaping MOMHandler = { _, _, _, _, _ in .success }
  ) -> Harness {
    let q = DispatchQueue(label: "test")
    let c = MOMController(options: options, queue: q, handler: appHandler)
    let p = MOMPeerContext.detached(controller: c, peerName: "test-peer")
    var sent: [(MOMPeerContext, Data)] = []
    c._sendHook = { peer, data in sent.append((peer, data)) }
    if asMaster {
      q.sync { c._setMasterPeer(p) }
    }
    return Harness(controller: c, peer: p, sent: { sent })
  }

  private func process(_ h: Harness, _ event: MOMEvent,
                       _ params: [MOMParameter] = []) -> MOMStatus {
    h.controller.queue.sync {
      h.controller._processEvent(peer: h.peer, eventWithType: event, params: params)
    }
  }

  // MARK: - Built-ins

  func testAliveRequestSucceeds() {
    let h = makeHarness()
    let s = process(h, .aliveRequest | .typeHostGetRequest)
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent().count, 1)
    XCTAssertEqual(h.sent()[0].1, Data(":aliverequest,0\r".utf8))
  }

  func testGetDeviceIDReturnsConfiguredValues() {
    var opts = MOMOptions(); opts.deviceID = 7; opts.deviceName = "Test"
    let h = makeHarness(options: opts)
    let s = process(h, .getDeviceID | .typeHostGetRequest)
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent()[0].1, Data(":gdevid,0,7,'Test'\r".utf8))
  }

  func testGetHardwareConfigRejectsWrongVersion() {
    let h = makeHarness()
    let s = process(h, .getHardwareConfig | .typeHostGetRequest, [.int(1)])
    XCTAssertEqual(s, .success)  // error reply was sent
    XCTAssertEqual(h.sent()[0].1, Data(":ghwconf,2,1\r".utf8))
  }

  func testGetHardwareConfigSuccess() {
    var opts = MOMOptions(); opts.serialNumber = "SN"; opts.systemTypeAndVersion = "SYS"
    let h = makeHarness(options: opts)
    let s = process(h, .getHardwareConfig | .typeHostGetRequest, [.int(2)])
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent()[0].1, Data(":ghwconf,0,2,1,'SYS','SN'\r".utf8))
  }

  func testGetSoftwareVersionSuccess() {
    var opts = MOMOptions()
    opts.cpuFirmwareTag = "cpu"; opts.cpuFirmwareVersion = "1.0"
    opts.recoveryFirmwareTag = "rec"; opts.recoveryFirmwareVersion = "0.9"
    let h = makeHarness(options: opts)
    let s = process(h, .getSoftwareVersion | .typeHostGetRequest, [.int(2)])
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent()[0].1,
                   Data(":gswver,0,2,'cpu','1.0','rec','0.9'\r".utf8))
  }

  func testGetAliveTimeReturnsDefault() {
    let h = makeHarness()
    let s = process(h, .getAliveTime | .typeHostGetRequest)
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent()[0].1, Data(":galivetime,0,20\r".utf8))
  }

  func testSetAliveTimeAcceptsValid() {
    let h = makeHarness()
    let s = process(h, .setAliveTime | .typeHostSetRequest, [.int(30)])
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.controller.queue.sync { h.controller._aliveTime }, 30)
  }

  func testSetAliveTimeRejectsOutOfRange() {
    let h = makeHarness()
    let s = process(h, .setAliveTime | .typeHostSetRequest, [.int(99)])
    XCTAssertEqual(s, .success)  // error reply sent
    XCTAssertEqual(h.sent()[0].1, Data(":salivetime,2,99\r".utf8))  // status=2 (.invalidParameter)
  }

  func testGetKeyModeRejectsOutOfRangeKey() {
    let h = makeHarness()
    let s = process(h, .getKeyMode | .typeHostGetRequest, [.int(99)])
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent()[0].1, Data(":gkeymode,2,99\r".utf8))
  }

  func testGetKeyModeSuccess() {
    let h = makeHarness()
    let s = process(h, .getKeyMode | .typeHostGetRequest, [.int(1)])
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent()[0].1, Data(":gkeymode,0,1,1,0\r".utf8))
  }

  // MARK: - Non-master gating

  func testNonMasterCantSendNonRequestOnRestrictedEvent() {
    // setKeyState is a HostNotification with event >= getKeyMode → master-only
    let h = makeHarness(asMaster: false)
    let s = process(h, .setKeyState | .typeHostNotification, [.int(1), .int(0)])
    XCTAssertEqual(s, .requiresMaster)
    XCTAssertTrue(h.sent().isEmpty)
  }

  func testNonMasterCanSendHostRequestEvenOnRestrictedEvent() {
    // getKeyMode is a HostGetRequest → always allowed
    let h = makeHarness(asMaster: false)
    let s = process(h, .getKeyMode | .typeHostGetRequest, [.int(1)])
    XCTAssertEqual(s, .success)
  }

  // MARK: - Type validation

  func testWrongTypeForEventIsInvalid() {
    // aliveRequest's only valid type is HostGetRequest
    let h = makeHarness()
    let s = process(h, .aliveRequest | .typeHostNotification)
    XCTAssertEqual(s, .invalidRequest)
    XCTAssertTrue(h.sent().isEmpty)
  }

  // MARK: - Fall-through to app handler

  func testContinueFallsThroughToAppHandler() {
    var appCalled = false
    var observedID: Int32 = -1
    var observedName = ""
    let h = makeHarness(appHandler: { c, _, evt, p, _ in
      appCalled = true
      observedID = c._options.deviceID
      observedName = c._options.deviceName
      XCTAssertEqual(evt.event, .setDeviceID)
      return .success
    })
    let s = process(h, .setDeviceID | .typeHostNotification,
                    [.int(42), .string("foo")])
    XCTAssertEqual(s, .success)
    XCTAssertTrue(appCalled)
    XCTAssertEqual(observedID, 42)
    XCTAssertEqual(observedName, "foo")
  }

  func testNoBuiltinCallsAppHandlerWithSendReplyForGetRequest() {
    let exp = expectation(description: "sendReply invoked")
    let h = makeHarness(appHandler: { c, peer, evt, p, sendReply in
      XCTAssertEqual(evt.event, .getKeyState)
      XCTAssertNotNil(sendReply)
      _ = sendReply?(c, peer, evt, .success, [.int(1)])
      exp.fulfill()
      return .success
    })
    let s = process(h, .getKeyState | .typeHostGetRequest, [.int(1)])
    XCTAssertEqual(s, .success)
    XCTAssertEqual(h.sent()[0].1, Data(":gkeystate,0,1\r".utf8))
    wait(for: [exp], timeout: 0.1)
  }

  func testNoBuiltinCallsAppHandlerWithNilSendReplyForNotification() {
    let exp = expectation(description: "app handler invoked")
    let h = makeHarness(appHandler: { _, _, evt, _, sendReply in
      XCTAssertEqual(evt.event, .setLedState)
      XCTAssertNil(sendReply)
      exp.fulfill()
      return .success
    })
    let s = process(h, .setLedState | .typeHostNotification, [.int(1), .int(0)])
    XCTAssertEqual(s, .success)
    wait(for: [exp], timeout: 0.1)
  }

  func testAppHandlerReturningContinueMapsToInvalidRequest() {
    let h = makeHarness(appHandler: { _, _, _, _, _ in .continue })
    let s = process(h, .setLedState | .typeHostNotification, [.int(1), .int(0)])
    XCTAssertEqual(s, .invalidRequest)
  }
}
