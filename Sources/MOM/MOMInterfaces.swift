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
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Iterate up-and-running IPv4 network interfaces (excluding loopback).
///
/// Returning `.continue` from `body` skips to the next interface; any other
/// status terminates iteration and is returned. If every callback returns
/// `.continue` (or no interface matches), the result is `.socketError` —
/// the C-compatible convention, letting callers distinguish "the body acted
/// on at least one interface" from "nothing was hit".
@discardableResult
public func MOMEnumerateInterfaces(
  _ body: (UnsafePointer<ifaddrs>) -> MOMStatus
) -> MOMStatus {
  var head: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&head) == 0, let first = head else {
    return .socketError
  }
  defer { freeifaddrs(head) }

  var status: MOMStatus = .socketError
  var ifp: UnsafeMutablePointer<ifaddrs>? = first
  while let cur = ifp {
    defer { ifp = cur.pointee.ifa_next }

    guard let addr = cur.pointee.ifa_addr,
          addr.pointee.sa_family == sa_family_t(AF_INET)
    else { continue }

    let flags = Int(cur.pointee.ifa_flags)
    if (flags & (Int(IFF_UP) | Int(IFF_RUNNING))) == 0 { continue }
    if (flags & Int(IFF_LOOPBACK)) != 0 { continue }

    let res = body(UnsafePointer(cur))
    if res == .continue { continue }
    status = res
    if res != .success { break }
  }
  return status
}
