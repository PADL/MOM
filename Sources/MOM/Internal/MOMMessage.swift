//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Encoder/decoder for the MOM wire protocol.
///
/// Wire format:
///   `<tag><event-name>[,<param>[,<param>...]]\r`
///
/// where `<tag>` is one of `? & % : !` and each `<param>` is either a
/// single-quoted string (`'foo'`), a bare base-10 integer, or empty for null.
///
/// On decode, tokens that are neither quoted strings nor integers are silently
/// dropped, matching the C parser's behavior (`CFNumberFormatter` returns nil
/// and the loop `continue`s).
enum MOMMessage {
  static let recordTerminator: UInt8 = 0x0D // \r
  static let maxEventNameLength = 16 // matches C parseEventName limit

  enum DecodeOutcome: Equatable {
    case ok(event: MOMEvent, params: [MOMParameter])
    /// A host get/set request with an unknown event name. The caller should
    /// send these bytes back to the peer as the negative reply.
    case unknownRequest(reply: Data)
    case invalid
  }

  // MARK: - Tag <-> MOMEvent (type bits)

  static func tagByte(for type: MOMEvent) -> UInt8 {
    switch type {
    case .typeHostGetRequest: 0x3F // ?
    case .typeHostSetRequest: 0x26 // &
    case .typeHostNotification: 0x25 // %
    case .typeDeviceReply: 0x3A // :
    case .typeDeviceNotification: 0x21 // !
    default: 0
    }
  }

  static func eventType(for tag: UInt8) -> MOMEvent? {
    switch tag {
    case 0x3F: .typeHostGetRequest
    case 0x26: .typeHostSetRequest
    case 0x25: .typeHostNotification
    case 0x3A: .typeDeviceReply
    case 0x21: .typeDeviceNotification
    default: nil
    }
  }

  // MARK: - Event <-> wire name

  static func name(for event: MOMEvent) -> String? {
    eventNames[event]
  }

  static func event(for name: String) -> MOMEvent? {
    eventsByName[name]
  }

  private static let eventNames: [MOMEvent: String] = [
    .enumerateDevices: "edev",
    .aliveRequest: "aliverequest",
    .identify: "sidentify",

    .getHardwareConfig: "ghwconf",
    .getSoftwareVersion: "gswver",
    .getDeviceInfo: "gdevinfo",

    .getMaster: "gmaster",
    .setMaster: "smaster",

    .getAliveTime: "galivetime",
    .setAliveTime: "salivetime",

    .getDeviceID: "gdevid",
    .setDeviceID: "sdevid",

    .getIPAddress: "gip",
    .setIPAddress: "sip",

    .getKeyMode: "gkeymode",
    .setKeyMode: "skeymode",

    .getKeyState: "gkeystate",
    .setKeyState: "skeystate",

    .getLedState: "gledstate",
    .setLedState: "sledstate",

    .getLedIntensity: "gledint",
    .setLedIntensity: "sledint",

    .getRotationCount: "grotcount",
    .setRotationCount: "srotcount",

    .getRingLedState: "gringledstate",
    .setRingLedState: "sringledstate",
  ]

  private static let eventsByName: [String: MOMEvent] =
    Dictionary(uniqueKeysWithValues: eventNames.map { ($1, $0) })

  // MARK: - Encode

  /// Build a device-side wire message (reply or notification).
  /// `event` carries both the event identifier and the type tag, e.g.
  /// `.enumerateDevices | .typeDeviceReply`. Returns nil if the event has
  /// no wire name.
  static func encode(_ event: MOMEvent, params: [MOMParameter]) -> Data? {
    let type = event.type
    precondition(
      type == .typeDeviceReply || type == .typeDeviceNotification,
      "encode is only valid for device-side messages"
    )
    guard let name = eventNames[event.event] else { return nil }

    var out = Data()
    out.reserveCapacity(name.count + 8 + params.count * 6)
    out.append(tagByte(for: type))
    out.append(contentsOf: name.utf8)

    for p in params {
      out.append(0x2C) // ,
      switch p {
      case let .string(s):
        out.append(0x27)
        out.append(contentsOf: s.utf8)
        out.append(0x27)
      case let .int(n):
        out.append(contentsOf: String(n).utf8)
      case let .bool(b):
        out.append(b ? 0x31 : 0x30)
      case .null:
        break
      }
    }

    out.append(recordTerminator)
    return out
  }

  /// Build the negative reply for an unparseable host request.
  /// The status byte is `0` for a Get request, `1` for Set.
  private static func errorReply(type: MOMEvent, eventName: String) -> Data {
    precondition(type == .typeHostGetRequest || type == .typeHostSetRequest)
    var out = Data()
    out.append(tagByte(for: type))
    out.append(contentsOf: eventName.utf8)
    out.append(0x2C)
    out.append(type == .typeHostGetRequest ? 0x30 : 0x31)
    out.append(recordTerminator)
    return out
  }

  // MARK: - Decode

  static func decode(_ data: Data) -> DecodeOutcome {
    guard let raw = String(data: data, encoding: .utf8) else { return .invalid }
    let trimmed = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

    let tokens = trimmed.split(separator: ",", omittingEmptySubsequences: false)
    guard let first = tokens.first, let tagScalar = first.unicodeScalars.first
    else { return .invalid }

    // Compare the full scalar: a non-ASCII leading character must not alias
    // a tag byte (the C parser matched the whole UniChar).
    guard tagScalar.isASCII, let type = eventType(for: UInt8(tagScalar.value))
    else { return .invalid }

    let name = String(first.dropFirst())
    guard !name.isEmpty, name.count <= maxEventNameLength else { return .invalid }
    guard let event = eventsByName[name] else {
      if type == .typeHostGetRequest || type == .typeHostSetRequest {
        return .unknownRequest(reply: errorReply(type: type, eventName: name))
      }
      return .invalid
    }

    var params: [MOMParameter] = []
    params.reserveCapacity(tokens.count - 1)
    for tok in tokens.dropFirst() {
      if tok.count >= 2, tok.first == "'", tok.last == "'" {
        params.append(.string(String(tok.dropFirst().dropLast())))
      } else if let n = Int32(tok) {
        params.append(.int(n))
      }
      // else: silently dropped, matching the C parser
    }
    return .ok(event: event | type, params: params)
  }
}
