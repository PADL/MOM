//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import Foundation

/// An event identifier on the MOM wire protocol.
///
/// A `MOMEvent` value packs two fields into one integer, matching the C API:
///   * an *event* (the low 24 bits) — e.g. `.setDeviceID`
///   * a *type*  (the high 8 bits)  — e.g. `.typeHostSetRequest`
///
/// Combine them with `|`:
///
///     let e: MOMEvent = .setDeviceID | .typeHostSetRequest
///     e.event   // .setDeviceID
///     e.type    // .typeHostSetRequest
///     e.isHostRequest
public struct MOMEvent: RawRepresentable, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  // MARK: Sentinel

  public static let none = MOMEvent(rawValue: 0)

  // MARK: API-only events (port state, not on the wire)

  public static let portError     = MOMEvent(rawValue: 1)
  public static let portClosed    = MOMEvent(rawValue: 2)
  public static let portOpen      = MOMEvent(rawValue: 3)
  public static let portReady     = MOMEvent(rawValue: 4)
  public static let portConnected = MOMEvent(rawValue: 5)

  // MARK: Wire events

  public static let enumerateDevices    = MOMEvent(rawValue: 6)
  public static let aliveRequest        = MOMEvent(rawValue: 7)
  public static let identify            = MOMEvent(rawValue: 8)

  public static let getHardwareConfig   = MOMEvent(rawValue: 9)
  public static let getSoftwareVersion  = MOMEvent(rawValue: 10)
  public static let getDeviceInfo       = MOMEvent(rawValue: 11)

  public static let getMaster           = MOMEvent(rawValue: 12)
  public static let setMaster           = MOMEvent(rawValue: 13)

  public static let getAliveTime        = MOMEvent(rawValue: 14)
  public static let setAliveTime        = MOMEvent(rawValue: 15)

  public static let getDeviceID         = MOMEvent(rawValue: 16)
  public static let setDeviceID         = MOMEvent(rawValue: 17)

  public static let getIPAddress        = MOMEvent(rawValue: 18)
  public static let setIPAddress        = MOMEvent(rawValue: 19)

  public static let getKeyMode          = MOMEvent(rawValue: 20)
  public static let setKeyMode          = MOMEvent(rawValue: 21)

  public static let getKeyState         = MOMEvent(rawValue: 22)
  public static let setKeyState         = MOMEvent(rawValue: 23)

  public static let getLedState         = MOMEvent(rawValue: 24)
  public static let setLedState         = MOMEvent(rawValue: 25)

  public static let getLedIntensity     = MOMEvent(rawValue: 26)
  public static let setLedIntensity     = MOMEvent(rawValue: 27)

  public static let getRotationCount    = MOMEvent(rawValue: 28)
  public static let setRotationCount    = MOMEvent(rawValue: 29)

  public static let getRingLedState     = MOMEvent(rawValue: 30)
  public static let setRingLedState     = MOMEvent(rawValue: 31)

  public static let max                 = setRingLedState

  // MARK: Type tags

  public static let typeHostGetRequest      = MOMEvent(rawValue: 0x01000000)
  public static let typeHostSetRequest      = MOMEvent(rawValue: 0x02000000)
  public static let typeHostNotification    = MOMEvent(rawValue: 0x04000000)
  public static let typeHostAny             = MOMEvent(rawValue: 0x0F000000)

  public static let typeDeviceReply         = MOMEvent(rawValue: 0x10000000)
  public static let typeDeviceNotification  = MOMEvent(rawValue: 0x20000000)
  public static let typeDeviceAny           = MOMEvent(rawValue: 0xF0000000)

  public static let typeMask  = MOMEvent(rawValue: 0xFF000000)
  public static let eventMask = MOMEvent(rawValue: ~typeMask.rawValue)

  // MARK: Combining

  public static func | (lhs: MOMEvent, rhs: MOMEvent) -> MOMEvent {
    MOMEvent(rawValue: lhs.rawValue | rhs.rawValue)
  }

  public static func |= (lhs: inout MOMEvent, rhs: MOMEvent) {
    lhs = lhs | rhs
  }

  // MARK: Accessors

  public var type:  MOMEvent { MOMEvent(rawValue: rawValue & Self.typeMask.rawValue) }
  public var event: MOMEvent { MOMEvent(rawValue: rawValue & Self.eventMask.rawValue) }

  public var isHostRequest: Bool {
    type == .typeHostGetRequest || type == .typeHostSetRequest
  }
  public var isHostNotification:   Bool { type == .typeHostNotification }
  public var isDeviceReply:        Bool { type == .typeDeviceReply }
  public var isDeviceNotification: Bool { type == .typeDeviceNotification }
}
