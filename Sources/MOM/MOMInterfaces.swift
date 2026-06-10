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
#elseif canImport(WinSDK)
import WinSDK
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An up-and-running, non-loopback IPv4 network interface, as yielded by
/// `MOMEnumerateInterfaces`.
public struct MOMInterface {
  /// The interface name (POSIX interface name, or the adapter's friendly
  /// name on Windows). Informational; use `index` to identify the interface
  /// to the OS.
  public let name: String

  /// The OS interface index (as used for `IP_PKTINFO` source pinning).
  public let index: UInt32

  /// A persistent identifier for the interface, where the platform has one:
  /// on Windows this is the adapter GUID (stable across reboots and address
  /// changes). POSIX has no equivalent, so it is nil there.
  ///
  /// Spelled module-qualified because WinSDK exports the C `UUID` typedef
  /// (an alias of `GUID`), which would otherwise be ambiguous here.
  #if canImport(FoundationEssentials)
  public let uuid: FoundationEssentials.UUID?
  #else
  public let uuid: Foundation.UUID?
  #endif

  /// The interface's IPv4 unicast address, in network byte order.
  public let address: in_addr

  /// Dotted-quad presentation of `address`.
  public var addressString: String { Socket.format(address) }
}

/// Iterate up-and-running IPv4 network interfaces (excluding loopback).
///
/// Returning `.continue` from `body` skips to the next interface; any other
/// status terminates iteration and is returned. If every callback returns
/// `.continue` (or no interface matches), the result is `.socketError` —
/// the C-compatible convention, letting callers distinguish "the body acted
/// on at least one interface" from "nothing was hit".
@discardableResult
public func MOMEnumerateInterfaces(
  _ body: (MOMInterface) -> MOMStatus
) -> MOMStatus {
  var status: MOMStatus = .socketError
  for interface in MOMInterface.all {
    let res = body(interface)
    if res == .continue { continue }
    status = res
    if res != .success { break }
  }
  return status
}

#if canImport(WinSDK)
extension MOMInterface {
  /// All up-and-running non-loopback IPv4 interfaces, one entry per unicast
  /// address, via `GetAdaptersAddresses`.
  static var all: [MOMInterface] {
    _ensureWinsock()
    let family = ULONG(AF_INET)

    var size: ULONG = 0
    _ = GetAdaptersAddresses(family, 0, nil, nil, &size)
    guard size > 0 else { return [] }

    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<IP_ADAPTER_ADDRESSES>.alignment
    )
    defer { raw.deallocate() }
    let buffer = raw.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES.self)
    guard GetAdaptersAddresses(family, 0, nil, buffer, &size) == 0 else { return [] }

    var interfaces: [MOMInterface] = []
    var adapter: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>? = buffer
    while let a = adapter {
      defer { adapter = a.pointee.Next }

      guard a.pointee.OperStatus == IfOperStatusUp,
            a.pointee.IfType != IF_TYPE_SOFTWARE_LOOPBACK
      else { continue }

      let name = a.pointee.FriendlyName.map { String(decodingCString: $0, as: UTF16.self) }
        ?? a.pointee.AdapterName.map { String(cString: $0) } ?? ""

      // AdapterName is the adapter GUID in registry form ("{XXXXXXXX-…}"),
      // persistent across reboots.
      let uuid = a.pointee.AdapterName.flatMap { cString -> UUID? in
        var guid = String(cString: cString)
        if guid.hasPrefix("{"), guid.hasSuffix("}") {
          guid = String(guid.dropFirst().dropLast())
        }
        return UUID(uuidString: guid)
      }

      var unicast = a.pointee.FirstUnicastAddress
      while let u = unicast {
        defer { unicast = u.pointee.Next }
        guard let sa = u.pointee.Address.lpSockaddr,
              sa.pointee.sa_family == sa_family_t(AF_INET)
        else { continue }

        interfaces.append(MOMInterface(
          name: name,
          index: a.pointee.IfIndex,
          uuid: uuid,
          address: sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
          }
        ))
      }
    }
    return interfaces
  }
}
#else
extension MOMInterface {
  /// All up-and-running non-loopback IPv4 interfaces, one entry per unicast
  /// address, via `getifaddrs`.
  static var all: [MOMInterface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }

    var interfaces: [MOMInterface] = []
    var ifp = head
    while let cur = ifp {
      defer { ifp = cur.pointee.ifa_next }

      guard let addr = cur.pointee.ifa_addr,
            addr.pointee.sa_family == sa_family_t(AF_INET)
      else { continue }

      let flags = Int(cur.pointee.ifa_flags)
      if (flags & (Int(IFF_UP) | Int(IFF_RUNNING))) == 0 { continue }
      if (flags & Int(IFF_LOOPBACK)) != 0 { continue }

      interfaces.append(MOMInterface(
        name: String(cString: cur.pointee.ifa_name),
        index: if_nametoindex(cur.pointee.ifa_name),
        // TODO: on Darwin, recover the persistent interface UUID via
        // SystemConfiguration (SCNetworkInterface).
        uuid: nil,
        address: addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          $0.pointee.sin_addr
        }
      ))
    }
    return interfaces
  }
}
#endif
