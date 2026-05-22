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
@_exported import Darwin
#elseif canImport(Glibc)
@_exported import Glibc
#endif
import Foundation

internal enum MOMPort {
  static let discoveryRequest: UInt16 = 10002
  static let control:          UInt16 = 10003
  static let discoveryReply:   UInt16 = 10004
}

internal enum MOMNet {
  /// `setsockopt(fd, level, name, &value, sizeof value)`; returns true on success.
  @discardableResult
  static func setOption<T>(_ fd: Int32, level: Int32, name: Int32, value: T) -> Bool {
    var v = value
    return withUnsafePointer(to: &v) { p in
      setsockopt(fd, level, name, p, socklen_t(MemoryLayout<T>.size)) == 0
    }
  }

  static func setReuseAddress(_ fd: Int32) -> Bool {
    setOption(fd, level: SOL_SOCKET, name: SO_REUSEADDR, value: Int32(1))
  }

  static func setReusePort(_ fd: Int32) -> Bool {
    setOption(fd, level: SOL_SOCKET, name: SO_REUSEPORT, value: Int32(1))
  }

  static func setBroadcast(_ fd: Int32) -> Bool {
    setOption(fd, level: SOL_SOCKET, name: SO_BROADCAST, value: Int32(1))
  }

  static func setNoDelay(_ fd: Int32) -> Bool {
    setOption(fd, level: Int32(IPPROTO_TCP), name: TCP_NODELAY, value: Int32(1))
  }

  static func setRecvPktInfo(_ fd: Int32) -> Bool {
    #if canImport(Darwin)
    return setOption(fd, level: Int32(IPPROTO_IP), name: IP_RECVPKTINFO, value: Int32(1))
    #else
    return setOption(fd, level: Int32(IPPROTO_IP), name: IP_PKTINFO, value: Int32(1))
    #endif
  }

  /// Close a fd silently, ignoring errors.
  static func close(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
  }

  /// Bind a UDP/TCP socket to (anyAddr, port). Returns true on success.
  static func bind(_ fd: Int32, port: UInt16, address: in_addr_t = INADDR_ANY) -> Bool {
    var sin = sockaddr_in()
    #if canImport(Darwin)
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr.s_addr = address
    return withUnsafePointer(to: &sin) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        #if canImport(Darwin)
        return Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        #else
        return Glibc.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        #endif
      }
    }
  }
}

/// Errno value of the last syscall.
internal var momErrno: Int32 {
  #if canImport(Darwin)
  return Darwin.errno
  #else
  return Glibc.errno
  #endif
}

internal func momStrError(_ err: Int32) -> String {
  String(cString: strerror(err))
}
