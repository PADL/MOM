//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public struct MOMOptions: Sendable {
  public var deviceID: Int32 = 10
  public var deviceName: String = "MOM"
  public var serialNumber: String = "71000000000"
  public var modelID: String = "710"
  public var systemTypeAndVersion: String = "710100A   171127"
  public var cpuFirmwareTag: String = "cpufw"
  public var cpuFirmwareVersion: String = "1.0.0.2"
  public var recoveryFirmwareTag: String = "recovery"
  public var recoveryFirmwareVersion: String = "1.0.0.2"

  /// Hostname or IPv4 literal. When non-nil, only this peer may connect.
  public var restrictToSpecifiedHost: String?

  /// Bind address for the listening sockets. nil → INADDR_ANY.
  public var localInterfaceAddress: sockaddr_in?

  public init() {}
}
