//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

// Windows-only compatibility shims. The networking code is written against
// the BSD-socket vocabulary (in_addr_t, sa_family_t, SO_REUSEPORT). WinSDK
// provides most Winsock types and functions directly (sockaddr_in, in_addr,
// in_pktinfo, cmsghdr, WSAPoll, GetAdaptersAddresses, …); this file fills in
// the handful of POSIX names it does not, so the shared source compiles
// unchanged on Windows.
#if canImport(WinSDK)
import WinSDK
import ucrt
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - POSIX type aliases absent on Windows

/// WinSDK exports the C `UUID` typedef (an alias of `GUID`), which collides
/// with Foundation's. MOM code that says `UUID` means Foundation's.
#if canImport(FoundationEssentials)
typealias UUID = FoundationEssentials.UUID
#else
typealias UUID = Foundation.UUID
#endif

/// IPv4 address in network byte order. POSIX `in_addr_t`; Winsock has no
/// such typedef but uses the same 32-bit unsigned representation.
typealias in_addr_t = UInt32

/// Address family field type. POSIX `sa_family_t`; Winsock spells it
/// `ADDRESS_FAMILY` (a `USHORT`).
typealias sa_family_t = ADDRESS_FAMILY

extension in_addr {
  /// The flat 32-bit address. Winsock buries it in the `S_un` union and the
  /// usual `s_addr` accessor is a C macro Swift can't see; re-expose it so
  /// shared code keeps using `.s_addr`.
  var s_addr: in_addr_t {
    get { S_un.S_addr }
    set { S_un.S_addr = newValue }
  }
}

extension in_pktinfo {
  /// POSIX `in_pktinfo` carries both `ipi_spec_dst` (the local/source address)
  /// and `ipi_addr` (the header destination); Windows `IN_PKTINFO` has only
  /// `ipi_addr`. The shared code pins the source address via `ipi_spec_dst`,
  /// which on Windows is exactly what `ipi_addr` does in an outbound
  /// `IP_PKTINFO`, so alias the two.
  var ipi_spec_dst: in_addr {
    get { ipi_addr }
    set { ipi_addr = newValue }
  }
}

// MARK: - Socket-option / extension-function constants

/// Windows has no `SO_REUSEPORT`; `SO_REUSEADDR` carries the semantics the
/// discovery socket needs (multiple binds to the broadcast port).
let SO_REUSEPORT = SO_REUSEADDR

/// The WinSDK macro imports as `Int32`; shared code expects the POSIX
/// `in_addr_t` (`UInt32`) spelling.
let INADDR_LOOPBACK = in_addr_t(WinSDK.INADDR_LOOPBACK)

/// `ioctlsocket` takes its command as `Int32`, but the imported `FIONBIO`
/// macro is a wider unsigned value; reinterpret it once here so call sites
/// can pass it directly.
let FIONBIO = Int32(bitPattern: UInt32(truncatingIfNeeded: WinSDK.FIONBIO))

/// `WSAID_WSARECVMSG` (mswsock.h). Used with `WSAIoctl(SIO_GET_EXTENSION_…)`
/// to obtain the `WSARecvMsg` function pointer; not surfaced by WinSDK.
let WSAID_WSARECVMSG = GUID(
  Data1: 0xf689_d7c8, Data2: 0x6f1f, Data3: 0x436b,
  Data4: (0x8a, 0x53, 0xe5, 0x4f, 0xe3, 0x51, 0xc3, 0x22)
)

/// `WSAID_WSASENDMSG` (mswsock.h). Companion of `WSAID_WSARECVMSG`.
let WSAID_WSASENDMSG = GUID(
  Data1: 0xa441_e712, Data2: 0x754f, Data3: 0x43ca,
  Data4: (0x84, 0xa7, 0x0d, 0xee, 0x44, 0xcf, 0x60, 0x6d)
)

// MARK: - Winsock bootstrap

/// The Winsock version we require: 2.2, encoded as the C `MAKEWORD(2, 2)`
/// (major in the low byte, minor in the high byte). 2.2 is the final Winsock
/// revision, available on every supported Windows.
private let winsockVersion2_2 = WORD(2) | WORD(2) << 8

/// One-shot `WSAStartup`. Referencing this (via `_ensureWinsock()`) before
/// the first socket call initialises Winsock exactly once per process.
private let _winsockInitialized: Bool = {
  var data = WSADATA()
  return WSAStartup(winsockVersion2_2, &data) == 0
}()

@discardableResult
func _ensureWinsock() -> Bool { _winsockInitialized }
#endif
