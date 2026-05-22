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
import Dispatch
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum MOMPort {
  static let discoveryRequest: UInt16 = 10002
  static let control: UInt16 = 10003
  static let discoveryReply: UInt16 = 10004
}

/// An owned IPv4 socket file descriptor.
///
/// Non-copyable: exactly one owner exists at any time, and the fd is closed
/// exactly once — by `deinit` when the value is dropped (e.g. on an error
/// path), or by whoever takes over via `detach()`. The intended lifecycle:
///
///     guard let sock = Socket.tcp() else { ... }
///     sock.setReuseAddress()
///     guard sock.bind(port: port) else { return nil }   // deinit closes
///     let fd = sock.detach()                            // ownership out
///     let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
///     src.setCancelHandler { Socket.close(fd) }         // new owner
///
/// All platform divergence (Darwin/Glibc socket-type constants, `sin_len`,
/// `in_pktinfo` field types, cmsg plumbing for `sendmsg`/`recvmsg`) is
/// confined to this file and `Cmsg`.
struct Socket: ~Copyable {
  let fd: Int32

  private init(_ fd: Int32) {
    self.fd = fd
  }

  deinit {
    Socket.close(fd)
  }

  static func tcp() -> Socket? {
    let fd = socket(AF_INET, Socket.streamType, 0)
    return fd >= 0 ? Socket(fd) : nil
  }

  static func udp() -> Socket? {
    let fd = socket(AF_INET, Socket.datagramType, 0)
    return fd >= 0 ? Socket(fd) : nil
  }

  /// Relinquish ownership of the fd without closing it. The caller (usually
  /// a `DispatchSource` cancel handler) becomes responsible for
  /// `Socket.close`-ing it.
  consuming func detach() -> Int32 {
    let fd = fd
    discard self
    return fd
  }

  // MARK: - Setup

  /// `setsockopt(fd, level, name, &value, sizeof value)`; returns true on success.
  @discardableResult
  func setOption<T>(level: Int32, name: Int32, value: T) -> Bool {
    withUnsafePointer(to: value) { p in
      setsockopt(fd, level, name, p, socklen_t(MemoryLayout<T>.size)) == 0
    }
  }

  @discardableResult
  func setReuseAddress() -> Bool {
    setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: Int32(1))
  }

  @discardableResult
  func setReusePort() -> Bool {
    setOption(level: SOL_SOCKET, name: SO_REUSEPORT, value: Int32(1))
  }

  @discardableResult
  func setBroadcast() -> Bool {
    setOption(level: SOL_SOCKET, name: SO_BROADCAST, value: Int32(1))
  }

  @discardableResult
  func setNoDelay() -> Bool {
    setOption(level: Int32(IPPROTO_TCP), name: TCP_NODELAY, value: Int32(1))
  }

  @discardableResult
  func setRecvPktInfo() -> Bool {
    #if canImport(Darwin)
    return setOption(level: Int32(IPPROTO_IP), name: IP_RECVPKTINFO, value: Int32(1))
    #else
    return setOption(level: Int32(IPPROTO_IP), name: IP_PKTINFO, value: Int32(1))
    #endif
  }

  /// `O_NONBLOCK | existing flags` via fcntl, so reads/writes/accepts on a
  /// dispatch queue can never stall.
  func makeNonBlocking() {
    Socket.makeNonBlocking(fd)
  }

  @discardableResult
  func bind(port: UInt16, address: in_addr_t = INADDR_ANY) -> Bool {
    var sin = Socket.ipv4Address(port: port, address: address)
    return withUnsafePointer(to: &sin) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        sysBind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  @discardableResult
  func listen(backlog: Int32) -> Bool {
    sysListen(fd, backlog) == 0
  }

  /// Accept a pending IPv4 connection on a listening fd, returning the owned
  /// client socket and filling in its address. Returns nil if there is
  /// nothing to accept or the peer is not IPv4. Static because the listening
  /// fd's ownership lives with its dispatch source after `detach()`.
  static func acceptIPv4(on fd: Int32, address: inout sockaddr_in) -> Socket? {
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let clientFD = withUnsafeMutablePointer(to: &address) { sp in
      sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        accept(fd, sa, &len)
      }
    }
    guard clientFD >= 0 else { return nil }
    guard address.sin_family == sa_family_t(AF_INET) else {
      Socket.close(clientFD)
      return nil
    }
    return Socket(clientFD)
  }

  // MARK: - Address / pktinfo factories

  /// Build a `sockaddr_in`, handling the Darwin-only `sin_len` field and the
  /// port byte-order conversion in one place.
  static func ipv4Address(port: UInt16, address: in_addr_t) -> sockaddr_in {
    var sin = sockaddr_in()
    #if canImport(Darwin)
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr.s_addr = address
    return sin
  }

  /// Build an `in_pktinfo`; `ipi_ifindex` is `UInt32` on Darwin and `Int32`
  /// on Linux/glibc.
  static func pktInfo(interfaceIndex: UInt32, specDst: in_addr) -> in_pktinfo {
    var pi = in_pktinfo()
    #if canImport(Darwin)
    pi.ipi_ifindex = CUnsignedInt(interfaceIndex)
    #else
    pi.ipi_ifindex = Int32(interfaceIndex)
    #endif
    pi.ipi_spec_dst = specDst
    return pi
  }

  // MARK: - Datagram I/O (raw fd: used after ownership moved to a source)

  /// `sendmsg` with an optional `IP_PKTINFO` ancillary message so the source
  /// address can be pinned to a specific interface.
  @discardableResult
  static func send(
    _ data: [UInt8],
    on fd: Int32,
    to peer: sockaddr_in,
    pktInfo: in_pktinfo? = nil
  ) -> Bool {
    var dst = peer
    var ctl = [UInt8](repeating: 0, count: Cmsg.space(MemoryLayout<in_pktinfo>.size))

    return data.withUnsafeBufferPointer { dataBuf -> Bool in
      ctl.withUnsafeMutableBufferPointer { ctlBuf -> Bool in
        var iov = iovec(
          iov_base: UnsafeMutableRawPointer(mutating: dataBuf.baseAddress!),
          iov_len: dataBuf.count
        )
        return withUnsafeMutablePointer(to: &iov) { iovP -> Bool in
          withUnsafeMutablePointer(to: &dst) { sinP -> Bool in
            sinP.withMemoryRebound(to: sockaddr.self, capacity: 1) { saP -> Bool in
              var msg = msghdr()
              msg.msg_name = UnsafeMutableRawPointer(saP)
              msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
              msg.msg_iov = iovP
              msg.msg_iovlen = 1
              if let pi = pktInfo {
                let written = Cmsg.writePktInfo(
                  pi, into: UnsafeMutableRawBufferPointer(ctlBuf)
                )
                if written == 0 { return false }
                msg.msg_control = UnsafeMutableRawPointer(ctlBuf.baseAddress!)
                msg.msg_controllen = .init(written)
              }
              return sendmsg(fd, &msg, 0) >= 0
            }
          }
        }
      }
    }
  }

  /// `recvmsg` returning the payload, the sender's address, and the
  /// `IP_PKTINFO` ancillary data (when the socket has `setRecvPktInfo()`).
  /// Returns nil when there is nothing to read.
  static func receive(
    on fd: Int32,
    capacity: Int
  ) -> (
    payload: [UInt8],
    from: sockaddr_in,
    pktInfo: in_pktinfo?
  )? {
    var packet = [UInt8](repeating: 0, count: capacity)
    var control = [UInt8](repeating: 0, count: 1024)
    var sin = sockaddr_in()

    let (n, pktInfo) = packet.withUnsafeMutableBufferPointer { pktBuf -> (Int, in_pktinfo?) in
      control.withUnsafeMutableBufferPointer { ctlBuf -> (Int, in_pktinfo?) in
        var iov = iovec(
          iov_base: UnsafeMutableRawPointer(pktBuf.baseAddress!),
          iov_len: pktBuf.count
        )
        return withUnsafeMutablePointer(to: &iov) { iovP in
          withUnsafeMutablePointer(to: &sin) { sinP in
            sinP.withMemoryRebound(to: sockaddr.self, capacity: 1) { saP in
              var msg = msghdr()
              msg.msg_name = UnsafeMutableRawPointer(saP)
              msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
              msg.msg_iov = iovP
              msg.msg_iovlen = 1
              msg.msg_control = UnsafeMutableRawPointer(ctlBuf.baseAddress!)
              msg.msg_controllen = .init(ctlBuf.count)
              msg.msg_flags = 0
              let len = recvmsg(fd, &msg, 0)
              if len < 0 { return (0, nil) }
              let ctl = UnsafeRawBufferPointer(
                start: ctlBuf.baseAddress,
                count: Int(msg.msg_controllen)
              )
              return (len, Cmsg.firstPktInfo(in: ctl))
            }
          }
        }
      }
    }
    guard n > 0 else { return nil }
    return (Array(packet.prefix(n)), sin, pktInfo)
  }

  // MARK: - Raw fd helpers

  /// Close a raw fd silently. For fds whose ownership left a `Socket` via
  /// `detach()` (dispatch-source cancel handlers).
  static func close(_ fd: Int32) {
    _ = sysClose(fd)
  }

  static func makeNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
  }

  static func format(_ addr: in_addr) -> String {
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var a = addr
    let cstr = inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
    return cstr.map { String(cString: $0) } ?? ""
  }

  // MARK: - Platform shims

  // SOCK_STREAM/SOCK_DGRAM are Int32 on Darwin and CInt enums on glibc.
  #if canImport(Darwin)
  static let streamType: Int32 = SOCK_STREAM
  static let datagramType: Int32 = SOCK_DGRAM
  #else
  static let streamType: Int32 = .init(SOCK_STREAM.rawValue)
  static let datagramType: Int32 = .init(SOCK_DGRAM.rawValue)
  #endif
}

// Module-qualified libc calls that collide with Socket member names.
#if canImport(Darwin)
private let sysBind = Darwin.bind
private let sysListen = Darwin.listen
private let sysClose = Darwin.close
#else
private let sysBind = Glibc.bind
private let sysListen = Glibc.listen
private let sysClose = Glibc.close
#endif

/// Errno value of the last syscall.
var momErrno: Int32 {
  #if canImport(Darwin)
  return Darwin.errno
  #else
  return Glibc.errno
  #endif
}

func momStrError(_ err: Int32) -> String {
  String(cString: strerror(err))
}
