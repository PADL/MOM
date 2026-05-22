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

/// IPv4 hostname/literal resolution via `getaddrinfo`. Replaces the C
/// version's `CFHost`-based path (which only worked on Apple).
internal enum MOMResolver {
  /// Synchronously resolve `host` to a list of IPv4 addresses (in network
  /// byte order). Accepts both hostnames and IPv4 literals. Returns an
  /// empty array on failure.
  ///
  /// This call may block on DNS. Avoid invoking it on the controller's
  /// dispatch queue.
  static func resolveIPv4(_ host: String) -> [in_addr_t] {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    #if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
    #else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #endif

    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result
    else { return [] }
    defer { freeaddrinfo(head) }

    var addresses: [in_addr_t] = []
    var p: UnsafeMutablePointer<addrinfo>? = head
    while let cur = p {
      defer { p = cur.pointee.ai_next }
      guard let sa = cur.pointee.ai_addr,
            sa.pointee.sa_family == sa_family_t(AF_INET)
      else { continue }
      let s = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_addr.s_addr
      }
      addresses.append(s)
    }
    return addresses
  }
}
