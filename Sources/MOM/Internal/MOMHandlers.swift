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

/// Built-in handlers for the MOM wire events.
///
/// A built-in handler may:
///   - return `.success` — the orchestrator builds and sends the reply
///   - return `.continue` — fall through to the user's application handler
///   - return any other status — the orchestrator sends the error reply
///
/// Mutating `params` follows the C convention: the eventual status code is
/// inserted at index 0 by the orchestrator, so handlers push reply values at
/// index 1 (or use `insert(_:at: 0)` to push before request params).
///
/// Handlers run on the controller's queue and may freely touch `_options`
/// and the other `_`-prefixed internals.
internal enum MOMHandlers {
  typealias Builtin = (
    _ controller: MOMController,
    _ peer: MOMPeerContext,
    _ event: MOMEvent,
    _ params: inout [MOMParam]
  ) -> MOMStatus

  struct Entry {
    let validTypes: MOMEvent      // mask of accepted MOMEvent.type values
    let handler: Builtin?
  }

  static let table: [MOMEvent: Entry] = [
    .aliveRequest:       Entry(validTypes: .typeHostGetRequest,   handler: aliveRequest),
    .identify:           Entry(validTypes: .typeHostSetRequest,   handler: nil),
    .getHardwareConfig:  Entry(validTypes: .typeHostGetRequest,   handler: getHardwareConfig),
    .getSoftwareVersion: Entry(validTypes: .typeHostGetRequest,   handler: getSoftwareVersion),
    .getDeviceInfo:      Entry(validTypes: .typeHostGetRequest,   handler: getDeviceInfo),
    .getMaster:          Entry(validTypes: .typeHostGetRequest,   handler: getMaster),
    .setMaster:          Entry(validTypes: .typeHostNotification, handler: setMaster),
    .getAliveTime:       Entry(validTypes: .typeHostGetRequest,   handler: getAliveTime),
    .setAliveTime:       Entry(validTypes: .typeHostSetRequest,   handler: setAliveTime),
    .getDeviceID:        Entry(validTypes: .typeHostGetRequest,   handler: getDeviceID),
    .setDeviceID:        Entry(validTypes: .typeHostNotification, handler: setDeviceID),
    .getIPAddress:       Entry(validTypes: .typeHostGetRequest,   handler: getIPAddress),
    .setIPAddress:       Entry(validTypes: .typeHostSetRequest,   handler: setIPAddress),
    .getKeyMode:         Entry(validTypes: .typeHostGetRequest,   handler: getKeyMode),
    .setKeyMode:         Entry(validTypes: .typeHostSetRequest,   handler: setKeyMode),
    .getKeyState:        Entry(validTypes: .typeHostGetRequest,   handler: nil),
    .getLedState:        Entry(validTypes: .typeHostGetRequest,   handler: nil),
    .setLedState:        Entry(validTypes: .typeHostNotification, handler: nil),
    .getLedIntensity:    Entry(validTypes: .typeHostGetRequest,   handler: nil),
    .setLedIntensity:    Entry(validTypes: .typeHostNotification, handler: nil),
    .getRotationCount:   Entry(validTypes: .typeHostGetRequest,   handler: nil),
    .setRotationCount:   Entry(validTypes: .typeHostNotification, handler: nil),
    .getRingLedState:    Entry(validTypes: .typeHostGetRequest,   handler: nil),
    .setRingLedState:    Entry(validTypes: .typeHostNotification, handler: nil),
  ]

  // Events numbered below this are valid against a non-master peer; at and
  // above this they require master (host requests are always allowed).
  static let nonMasterEventCeiling = MOMEvent.getKeyMode.rawValue

  static func isValidOnNonMaster(_ eventWithType: MOMEvent) -> Bool {
    eventWithType.isHostRequest || eventWithType.event.rawValue < nonMasterEventCeiling
  }

  // MARK: - Param helpers

  private static func int(_ p: MOMParam?) -> Int32? {
    if case .int(let v) = p { return v }
    return nil
  }

  private static func string(_ p: MOMParam?) -> String? {
    if case .string(let v) = p { return v }
    return nil
  }

  // MARK: - Built-in handlers

  // HostGetRequest — keep-alive ping.
  private static func aliveRequest(_ c: MOMController, _ peer: MOMPeerContext,
                                   _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    .success
  }

  // HostGetRequest — `<version=2>` → `[<version>, 1, systemTypeAndVersion, serialNumber]`
  private static func getHardwareConfig(_ c: MOMController, _ peer: MOMPeerContext,
                                        _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    guard let v = int(p.first) else { return .invalidRequest }
    guard v == 2 else { return .invalidParameter }
    p.insert(.string(c._options.serialNumber), at: 1)
    p.insert(.string(c._options.systemTypeAndVersion), at: 1)
    p.insert(.int(1), at: 1)
    return .success
  }

  // HostGetRequest — `<version=2>` → `[<version>, cpuTag, cpuVer, recTag, recVer]`
  private static func getSoftwareVersion(_ c: MOMController, _ peer: MOMPeerContext,
                                         _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    guard let v = int(p.first) else { return .invalidRequest }
    guard v == 2 else { return .invalidParameter }
    p.insert(.string(c._options.recoveryFirmwareVersion), at: 1)
    p.insert(.string(c._options.recoveryFirmwareTag),     at: 1)
    p.insert(.string(c._options.cpuFirmwareVersion),      at: 1)
    p.insert(.string(c._options.cpuFirmwareTag),          at: 1)
    return .success
  }

  // HostGetRequest — `[]` → `[modelID, 0, serialNumber]`
  private static func getDeviceInfo(_ c: MOMController, _ peer: MOMPeerContext,
                                    _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    p.insert(.string(c._options.modelID),      at: 0)
    p.insert(.int(0),                          at: 0)
    p.insert(.string(c._options.serialNumber), at: 0)
    return .success
  }

  // HostGetRequest — `[]` → `[isMaster?]`
  private static func getMaster(_ c: MOMController, _ peer: MOMPeerContext,
                                _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    p.insert(.int(c._isPeerMaster(peer) ? 1 : 0), at: 0)
    return .success
  }

  // HostNotification — `<master>`
  private static func setMaster(_ c: MOMController, _ peer: MOMPeerContext,
                                _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    guard let m = int(p.first) else { return .invalidRequest }
    c._setMasterPeer(m != 0 ? peer : nil)
    c._setPeerPortStatus(peer, m != 0 ? .connected : .ready)
    return .success
  }

  // HostGetRequest — `[]` → `[aliveTime]`
  private static func getAliveTime(_ c: MOMController, _ peer: MOMPeerContext,
                                   _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    p.insert(.int(c._aliveTime), at: 0)
    return .success
  }

  // HostSetRequest — `<aliveTime>`. Last thing DADman sends before "ready".
  private static func setAliveTime(_ c: MOMController, _ peer: MOMPeerContext,
                                   _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    guard let t = int(p.first) else { return .invalidRequest }
    guard c._setAliveTime(t) else { return .invalidParameter }
    if c._peerPortStatus(peer).rawValue < MOMPortStatus.ready.rawValue {
      c._setPeerPortStatus(peer, .ready)
    }
    return .success
  }

  // HostGetRequest — `[]` → `[deviceID, deviceName]`
  private static func getDeviceID(_ c: MOMController, _ peer: MOMPeerContext,
                                  _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    p.insert(.string(c._options.deviceName), at: 0)
    p.insert(.int(c._options.deviceID),      at: 0)
    return .success
  }

  // HostNotification — `<deviceID>, <deviceName>`
  private static func setDeviceID(_ c: MOMController, _ peer: MOMPeerContext,
                                  _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    guard let id = int(p.first), id >= 1 else {
      return int(p.first) == nil ? .invalidRequest : .invalidParameter
    }
    guard let name = p.count > 1 ? string(p[1]) : nil else { return .invalidRequest }
    c._options.deviceID = id
    c._options.deviceName = name
    return .continue   // let the user's handler observe the update too
  }

  // HostGetRequest — `[]` → `[1, "", "", "", ""]` (stub IP info).
  private static func getIPAddress(_ c: MOMController, _ peer: MOMPeerContext,
                                   _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    p.insert(.string(""), at: 0)  // MAC
    p.insert(.string(""), at: 0)  // router
    p.insert(.string(""), at: 0)  // mask
    p.insert(.string(""), at: 0)  // IP
    p.insert(.int(1),     at: 0)  // DHCP
    return .success
  }

  // HostSetRequest — defer to user handler.
  private static func setIPAddress(_ c: MOMController, _ peer: MOMPeerContext,
                                   _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    .continue
  }

  // HostGetRequest — `<keyNumber>` → `[<keyNumber>, 1, 0]` (mode + unknown)
  private static func getKeyMode(_ c: MOMController, _ peer: MOMPeerContext,
                                 _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    guard let n = int(p.first) else { return .invalidRequest }
    guard let _ = MOMKeyID(rawValue: Int(n)) else { return .invalidParameter }
    p.insert(.int(0), at: 1)
    p.insert(.int(1), at: 1)
    return .success
  }

  // HostSetRequest — `<keyNumber>, <keyMode>, <unknown>`
  private static func setKeyMode(_ c: MOMController, _ peer: MOMPeerContext,
                                 _ event: MOMEvent, _ p: inout [MOMParam]) -> MOMStatus {
    guard p.count >= 3,
          let n = int(p[0]), let m = int(p[1]), let _ = int(p[2])
    else { return .invalidRequest }
    guard MOMKeyID(rawValue: Int(n)) != nil else { return .invalidParameter }
    guard m == 1 else { return .invalidParameter }
    return .success
  }
}
