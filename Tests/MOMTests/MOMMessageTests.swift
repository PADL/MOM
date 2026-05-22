//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
//

import XCTest
@testable import MOM

final class MOMMessageTests: XCTestCase {
  // MARK: - MOMEvent bitfield

  func testEventTypeAndEventAccessors() {
    let e: MOMEvent = .setDeviceID | .typeHostSetRequest
    XCTAssertEqual(e.type, .typeHostSetRequest)
    XCTAssertEqual(e.event, .setDeviceID)
    XCTAssertTrue(e.isHostRequest)
    XCTAssertFalse(e.isDeviceReply)
  }

  // MARK: - Encode

  func testEncodeReplyNoParams() {
    let bytes = MOMMessage.encode(.aliveRequest | .typeDeviceReply, params: [])
    XCTAssertEqual(bytes, Data(":aliverequest\r".utf8))
  }

  func testEncodeReplyMixedParams() {
    let bytes = MOMMessage.encode(
      .enumerateDevices | .typeDeviceReply,
      params: [.string("71000000000"), .int(0), .string("710"),
               .string("DAD-MOM"), .int(1), .int(1), .int(0)]
    )
    XCTAssertEqual(bytes,
                   Data(":edev,'71000000000',0,'710','DAD-MOM',1,1,0\r".utf8))
  }

  func testEncodeNotification() {
    let bytes = MOMMessage.encode(
      .setKeyState | .typeDeviceNotification,
      params: [.int(1), .int(0)]
    )
    XCTAssertEqual(bytes, Data("!skeystate,1,0\r".utf8))
  }

  func testEncodeBoolAndNull() {
    let bytes = MOMMessage.encode(
      .setLedState | .typeDeviceReply,
      params: [.bool(true), .null, .bool(false)]
    )
    XCTAssertEqual(bytes, Data(":sledstate,1,,0\r".utf8))
  }

  // MARK: - Decode

  func testDecodeHostGetRequest() {
    let res = MOMMessage.decode(Data("?gdevid\r".utf8))
    guard case .ok(let event, let params) = res else {
      XCTFail("expected ok, got \(res)"); return
    }
    XCTAssertEqual(event.type, .typeHostGetRequest)
    XCTAssertEqual(event.event, .getDeviceID)
    XCTAssertTrue(params.isEmpty)
  }

  func testDecodeHostNotificationWithParams() {
    let res = MOMMessage.decode(Data("%sdevid,42,'mom-front'\r".utf8))
    guard case .ok(let event, let params) = res else {
      XCTFail("expected ok, got \(res)"); return
    }
    XCTAssertEqual(event.type, .typeHostNotification)
    XCTAssertEqual(event.event, .setDeviceID)
    XCTAssertEqual(params, [.int(42), .string("mom-front")])
  }

  func testDecodeDropsGarbageTokens() {
    // 'foo bar' is a real string (kept); plain `xyz` is dropped (matches C)
    let res = MOMMessage.decode(Data("&skeystate,xyz,'ok',7\r".utf8))
    guard case .ok(_, let params) = res else {
      XCTFail("expected ok, got \(res)"); return
    }
    XCTAssertEqual(params, [.string("ok"), .int(7)])
  }

  func testDecodeNegativeInt() {
    let res = MOMMessage.decode(Data("&srotcount,-5\r".utf8))
    guard case .ok(_, let params) = res else {
      XCTFail("expected ok, got \(res)"); return
    }
    XCTAssertEqual(params, [.int(-5)])
  }

  // MARK: - Decode error paths

  func testDecodeUnknownGetRequestProducesErrorReply() {
    let res = MOMMessage.decode(Data("?bogus\r".utf8))
    guard case .unknownRequest(let reply) = res else {
      XCTFail("expected unknownRequest, got \(res)"); return
    }
    XCTAssertEqual(reply, Data("?bogus,0\r".utf8))
  }

  func testDecodeUnknownSetRequestProducesErrorReply() {
    let res = MOMMessage.decode(Data("&bogus\r".utf8))
    guard case .unknownRequest(let reply) = res else {
      XCTFail("expected unknownRequest, got \(res)"); return
    }
    XCTAssertEqual(reply, Data("&bogus,1\r".utf8))
  }

  func testDecodeUnknownNotificationIsInvalid() {
    // Notifications don't get error replies
    let res = MOMMessage.decode(Data("%bogus\r".utf8))
    XCTAssertEqual(res, .invalid)
  }

  func testDecodeBadTagIsInvalid() {
    let res = MOMMessage.decode(Data("@gdevid\r".utf8))
    XCTAssertEqual(res, .invalid)
  }

  func testDecodeOversizedNameIsInvalid() {
    // 17 chars (over the 16-char limit) → rejected as if unknown
    let res = MOMMessage.decode(Data("?abcdefghijklmnopq\r".utf8))
    XCTAssertEqual(res, .invalid)
  }

  // MARK: - Round-trip

  func testRoundTripNotification() {
    let original: MOMEvent = .setLedIntensity | .typeDeviceNotification
    let params: [MOMParam] = [.int(2), .string("foo")]
    let encoded = MOMMessage.encode(original, params: params)!

    // Device-side encoded messages aren't normally decoded by the same parser,
    // but the codec is symmetric for tag/name/params, so this validates that.
    let decoded = MOMMessage.decode(encoded)
    guard case .ok(let event, let p) = decoded else {
      XCTFail("expected ok, got \(decoded)"); return
    }
    XCTAssertEqual(event, original)
    XCTAssertEqual(p, params)
  }
}
