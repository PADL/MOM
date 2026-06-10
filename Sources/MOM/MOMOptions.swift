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

/// Device configuration, backed by a string-keyed dictionary.
///
/// Typed accessors cover the fields MOM itself uses; arbitrary entries can be
/// set via `subscript`, so a client can keep its own settings alongside the
/// device configuration in a single store. The raw `dictionary` is exposed
/// for compatibility with dictionary-based APIs, and is the serialized form.
///
/// The wire keys depend on the `MOMStreamDeckPlugin` package trait: snake_case
/// (`device_id`) when the trait is enabled, the legacy `kMOM*` names
/// otherwise — preserving the exact keys each client persisted.
///
/// The raw `dictionary` *is* the serialized form: hand it straight to a
/// `[String: Any]` persistence API. It's `[String: Any]` (not
/// `[String: any Sendable]`) precisely so those `[String: Any]` APIs — and
/// values arriving from them — pass through without per-value normalization;
/// `Sendable` can't be conditionally cast, so an `any Sendable` store couldn't
/// ingest an `Any`. `@unchecked Sendable` is the honest promise for a value
/// type carrying plist scalars that's copied across the controller's queue.
///
/// Transient network state (e.g. the local bind interface) is deliberately
/// *not* here — it lives on `MOMController` so options stay purely the
/// persistable configuration.
public struct MOMOptions: @unchecked Sendable {
  /// The raw backing store. Keys are the wire keys (see `Key`); directly
  /// usable with dictionary-based persistence APIs.
  public var dictionary: [String: Any]

  /// Seed a fresh options set with the default device configuration (mirrors
  /// the values the C library seeded into its options dictionary at create).
  public init() {
    dictionary = [
      Key.deviceID: Int(10),
      Key.deviceName: "MOM",
      Key.modelID: "710",
      Key.serialNumber: "71000000000",
      Key.systemTypeAndVersion: "710100A   171127",
      Key.cpuFirmwareTag: "cpufw",
      Key.cpuFirmwareVersion: "1.0.0.2",
      Key.recoveryFirmwareTag: "recovery",
      Key.recoveryFirmwareVersion: "1.0.0.2",
    ]
    // restrictToSpecifiedHost is absent by default (C parity: NULL).
  }

  /// Start from the defaults, then overlay the supplied entries (C parity:
  /// copy the caller's options, then fill in any missing defaults).
  public init(dictionary: [String: Any]) {
    self.init()
    for (key, value) in dictionary {
      self.dictionary[key] = value
    }
  }

  /// Get/set an arbitrary entry. Setting `nil` removes the key.
  public subscript(key: String) -> Any? {
    get { dictionary[key] }
    set {
      if let newValue {
        dictionary[key] = newValue
      } else {
        dictionary.removeValue(forKey: key)
      }
    }
  }

  /// Wire keys for the typed device fields.
  public enum Key {
    #if MOMStreamDeckPlugin
    public static let deviceID = "device_id"
    public static let deviceName = "device_name"
    public static let serialNumber = "serial_number"
    public static let modelID = "model_id"
    public static let systemTypeAndVersion = "system_type_and_version"
    public static let cpuFirmwareTag = "cpu_firmware_tag"
    public static let cpuFirmwareVersion = "cpu_firmware_version"
    public static let recoveryFirmwareTag = "recovery_firmware_tag"
    public static let recoveryFirmwareVersion = "recovery_firmware_version"
    public static let restrictToSpecifiedHost = "restrict_to_specified_host"
    #else
    public static let deviceID = "kMOMDeviceID"
    public static let deviceName = "kMOMDeviceName"
    public static let serialNumber = "kMOMSerialNumber"
    public static let modelID = "kMOMModelID"
    public static let systemTypeAndVersion = "kMOMSystemTypeAndVersion"
    public static let cpuFirmwareTag = "kMOMCPUFirmwareTag"
    public static let cpuFirmwareVersion = "kMOMCPUFirmwareVersion"
    public static let recoveryFirmwareTag = "kMOMRecoveryFirmwareTag"
    public static let recoveryFirmwareVersion = "kMOMRecoveryFirmwareVersion"
    public static let restrictToSpecifiedHost = "kMOMRestrictToSpecifiedHost"
    #endif
  }

  private func string(_ key: String, or fallback: String) -> String {
    dictionary[key] as? String ?? fallback
  }

  public var deviceID: Int32 {
    get {
      if let value = dictionary[Key.deviceID] as? Int { return Int32(value) }
      if let value = dictionary[Key.deviceID] as? Int32 { return value }
      return 10
    }
    set { dictionary[Key.deviceID] = Int(newValue) }
  }

  public var deviceName: String {
    get { string(Key.deviceName, or: "MOM") }
    set { dictionary[Key.deviceName] = newValue }
  }

  public var serialNumber: String {
    get { string(Key.serialNumber, or: "71000000000") }
    set { dictionary[Key.serialNumber] = newValue }
  }

  public var modelID: String {
    get { string(Key.modelID, or: "710") }
    set { dictionary[Key.modelID] = newValue }
  }

  public var systemTypeAndVersion: String {
    get { string(Key.systemTypeAndVersion, or: "710100A   171127") }
    set { dictionary[Key.systemTypeAndVersion] = newValue }
  }

  public var cpuFirmwareTag: String {
    get { string(Key.cpuFirmwareTag, or: "cpufw") }
    set { dictionary[Key.cpuFirmwareTag] = newValue }
  }

  public var cpuFirmwareVersion: String {
    get { string(Key.cpuFirmwareVersion, or: "1.0.0.2") }
    set { dictionary[Key.cpuFirmwareVersion] = newValue }
  }

  public var recoveryFirmwareTag: String {
    get { string(Key.recoveryFirmwareTag, or: "recovery") }
    set { dictionary[Key.recoveryFirmwareTag] = newValue }
  }

  public var recoveryFirmwareVersion: String {
    get { string(Key.recoveryFirmwareVersion, or: "1.0.0.2") }
    set { dictionary[Key.recoveryFirmwareVersion] = newValue }
  }

  /// Hostname or IPv4 literal. When non-nil, only this peer may connect.
  public var restrictToSpecifiedHost: String? {
    get { dictionary[Key.restrictToSpecifiedHost] as? String }
    set {
      if let newValue {
        dictionary[Key.restrictToSpecifiedHost] = newValue
      } else {
        dictionary.removeValue(forKey: Key.restrictToSpecifiedHost)
      }
    }
  }
}
