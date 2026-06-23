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
#elseif canImport(WinSDK)
@_exported import WinSDK
@_exported import ucrt
#endif
import Dispatch
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum MOMPort: UInt16 {
  case discoveryRequest = 10002
  case control = 10003
  case discoveryReply = 10004
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
///     let src = IOReadinessSource.read(fd: fd, queue: q)
///     src.setCancelHandler { Socket.close(fd) }         // new owner
///
/// All platform divergence (socket-type constants, `sin_len`, `in_pktinfo`
/// field types, `sendmsg`/`WSASendMsg` message packaging) is confined to
/// this file and `Cmsg`.
struct Socket: ~Copyable {
  #if canImport(WinSDK)
  typealias SocketDescriptor = SOCKET
  static let invalidDescriptor: SocketDescriptor = INVALID_SOCKET
  #else
  typealias SocketDescriptor = Int32
  static let invalidDescriptor: SocketDescriptor = -1
  #endif

  // Internal (not private) so white-box tests can observe a live socket's
  // descriptor (e.g. asserting deinit closes it); library consumers never
  // see it.
  let fd: SocketDescriptor

  private init(_ fd: SocketDescriptor) {
    self.fd = fd
  }

  deinit {
    Socket.close(fd)
  }

  static func tcp() -> Socket? {
    makeSocket(Socket.streamType)
  }

  static func udp() -> Socket? {
    makeSocket(Socket.datagramType)
  }

  private static func makeSocket(_ type: Int32) -> Socket? {
    #if canImport(WinSDK)
    _ensureWinsock()
    #endif
    let fd = socket(AF_INET, type, 0)
    return fd != Socket.invalidDescriptor ? Socket(fd) : nil
  }

  /// Relinquish ownership of the fd without closing it. The caller (usually
  /// a `DispatchSource` cancel handler) becomes responsible for
  /// `Socket.close`-ing it.
  consuming func detach() -> SocketDescriptor {
    let fd = fd
    discard self
    return fd
  }

  // MARK: - Setup

  /// `setsockopt(fd, level, name, &value, sizeof value)`; returns true on success.
  @discardableResult
  func setOption<T>(level: Int32, name: Int32, value: T) -> Bool {
#if canImport(WinSDK)
    withUnsafePointer(to: value) { p in
      p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { p in
        setsockopt(fd, level, name, p, Int32(MemoryLayout<T>.size)) == 0
      }
    }
#else
    withUnsafePointer(to: value) { p in
      setsockopt(fd, level, name, p, socklen_t(MemoryLayout<T>.size)) == 0
    }
#endif
  }

  @discardableResult
  func setReuseAddress() -> Bool {
    setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: Int32(1))
  }

  @discardableResult
  func setReusePort() -> Bool {
    // SO_REUSEPORT aliases SO_REUSEADDR on Windows (see WinSDKCompat); the
    // single setsockopt is harmless even if the discovery socket already set
    // SO_REUSEADDR.
    setOption(level: SOL_SOCKET, name: SO_REUSEPORT, value: Int32(1))
  }

  @discardableResult
  func setBroadcast() -> Bool {
    setOption(level: SOL_SOCKET, name: SO_BROADCAST, value: Int32(1))
  }

  @discardableResult
  func setNoDelay() -> Bool {
    setOption(level: IPPROTO_TCP, name: TCP_NODELAY, value: Int32(1))
  }

  @discardableResult
  func setRecvPktInfo() -> Bool {
    #if canImport(Darwin)
    return setOption(level: IPPROTO_IP, name: IP_RECVPKTINFO, value: Int32(1))
    #else
    return setOption(level: IPPROTO_IP, name: IP_PKTINFO, value: Int32(1))
    #endif
  }

  /// Mark the socket non-blocking (fcntl `O_NONBLOCK` / `FIONBIO` ioctl), so
  /// reads/writes/accepts on a dispatch queue can never stall.
  func makeNonBlocking() {
    Socket.makeNonBlocking(fd)
  }

  @discardableResult
  func bind(port: UInt16, address: in_addr_t = INADDR_ANY) -> Bool {
    var sin = Socket.ipv4Address(port: port, address: address)
    return sin.withSockaddr { sa, saLen in
      sysBind(fd, sa, saLen) == 0
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
  static func acceptIPv4(on fd: SocketDescriptor, address: inout sockaddr_in) -> Socket? {
    let clientFD = address.withSockaddr { sa, saLen in
      var len = saLen
      return sysAccept(fd, sa, &len)
    }
    // SOCKET is unsigned on Windows, so compare against the invalid sentinel
    // rather than `>= 0` (which would be vacuously true there).
    guard clientFD != Socket.invalidDescriptor else { return nil }
    guard address.sin_family == sa_family_t(AF_INET) else {
      Socket.close(clientFD)
      return nil
    }
    return Socket(clientFD)
  }

  /// The socket's local address (`getsockname`), or nil on failure or a
  /// non-IPv4 binding. For an accepted TCP socket this is the host address the
  /// peer connected to, which identifies the arrival interface.
  func localAddress() -> sockaddr_in? {
    var sin = sockaddr_in()
    let ok = sin.withSockaddr { sa, saLen in
      var len = saLen
      return sysGetsockname(fd, sa, &len) == 0
    }
    guard ok, sin.sin_family == sa_family_t(AF_INET) else { return nil }
    return sin
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
    #elseif canImport(WinSDK)
    pi.ipi_ifindex = .init(interfaceIndex)
    #else
    pi.ipi_ifindex = Int32(interfaceIndex)
    #endif
    pi.ipi_spec_dst = specDst
    return pi
  }

  // MARK: - Datagram I/O (raw fd: used after ownership moved to a source)

  /// Shared scaffolding for the platform send paths: pins the payload, a
  /// cmsg-sized control buffer (pre-filled from `pktInfo` when present, nil
  /// otherwise), and the destination address, leaving only the platform's
  /// message packaging and syscall to `body`.
  private static func withDatagramSend(
    _ data: [UInt8],
    to peer: sockaddr_in,
    pktInfo: in_pktinfo?,
    _ body: (
      _ payload: UnsafeMutableRawBufferPointer,
      _ control: UnsafeMutableRawBufferPointer?,
      _ sa: UnsafeMutablePointer<sockaddr>,
      _ saLen: socklen_t
    ) -> Bool
  ) -> Bool {
    var dst = peer
    var payload = data
    var ctl = [UInt8](repeating: 0, count: Cmsg.space(MemoryLayout<in_pktinfo>.size))

    return payload.withUnsafeMutableBytes { dataRaw in
      ctl.withUnsafeMutableBytes { ctlRaw in
        dst.withSockaddr { sa, saLen in
          var control: UnsafeMutableRawBufferPointer?
          if let pi = pktInfo {
            let written = Cmsg.writePktInfo(pi, into: ctlRaw)
            guard written > 0 else { return false }
            control = UnsafeMutableRawBufferPointer(rebasing: ctlRaw[..<written])
          }
          return body(dataRaw, control, sa, saLen)
        }
      }
    }
  }

  /// Shared scaffolding for the platform receive paths: pins a packet buffer,
  /// a control buffer, and an address to fill in, then assembles `body`'s
  /// (length, pktinfo) result into the public return shape.
  private static func withDatagramReceive(
    capacity: Int,
    _ body: (
      _ packet: UnsafeMutableRawBufferPointer,
      _ control: UnsafeMutableRawBufferPointer,
      _ sa: UnsafeMutablePointer<sockaddr>,
      _ saLen: socklen_t
    ) -> (Int, in_pktinfo?)
  ) -> (payload: [UInt8], from: sockaddr_in, pktInfo: in_pktinfo?)? {
    var packet = [UInt8](repeating: 0, count: capacity)
    var control = [UInt8](repeating: 0, count: 1024)
    var sin = sockaddr_in()

    let (n, pktInfo) = packet.withUnsafeMutableBytes { pktRaw in
      control.withUnsafeMutableBytes { ctlRaw in
        sin.withSockaddr { sa, saLen in
          body(pktRaw, ctlRaw, sa, saLen)
        }
      }
    }
    guard n > 0 else { return nil }
    return (Array(packet.prefix(n)), sin, pktInfo)
  }

  /// `sendmsg`/`WSASendMsg` with an optional `IP_PKTINFO` ancillary message
  /// so the source address can be pinned to a specific interface.
  @discardableResult
  static func send(
    _ data: [UInt8],
    on fd: SocketDescriptor,
    to peer: sockaddr_in,
    pktInfo: in_pktinfo? = nil
  ) -> Bool {
    #if canImport(WinSDK)
    guard let sendFn = _wsaExtensions.send else { return false }
    #endif
    return withDatagramSend(data, to: peer, pktInfo: pktInfo) { payload, control, sa, saLen in
      #if canImport(WinSDK)
      var wsabuf = WSABUF(
        len: ULONG(payload.count),
        buf: payload.baseAddress?.assumingMemoryBound(to: CChar.self)
      )
      return withUnsafeMutablePointer(to: &wsabuf) { bufP in
        var msg = WSAMSG()
        msg.name = sa
        msg.namelen = INT(saLen)
        msg.lpBuffers = bufP
        msg.dwBufferCount = 1
        msg.dwFlags = 0
        if let control {
          msg.Control = WSABUF(
            len: ULONG(control.count),
            buf: control.baseAddress?.assumingMemoryBound(to: CChar.self)
          )
        } else {
          msg.Control = WSABUF(len: 0, buf: nil)
        }
        var sent: DWORD = 0
        return sendFn(fd, &msg, 0, &sent, nil, nil) == 0
      }
      #else
      var iov = iovec(iov_base: payload.baseAddress, iov_len: payload.count)
      return withUnsafeMutablePointer(to: &iov) { iovP in
        var msg = msghdr()
        msg.msg_name = UnsafeMutableRawPointer(sa)
        msg.msg_namelen = saLen
        msg.msg_iov = iovP
        msg.msg_iovlen = 1
        if let control {
          msg.msg_control = control.baseAddress
          msg.msg_controllen = .init(control.count)
        }
        return sendmsg(fd, &msg, 0) >= 0
      }
      #endif
    }
  }

  /// `recvmsg`/`WSARecvMsg` returning the payload, the sender's address, and
  /// the `IP_PKTINFO` ancillary data (when the socket has `setRecvPktInfo()`).
  /// Returns nil when there is nothing to read.
  static func receive(
    on fd: SocketDescriptor,
    capacity: Int
  ) -> (
    payload: [UInt8],
    from: sockaddr_in,
    pktInfo: in_pktinfo?
  )? {
    #if canImport(WinSDK)
    guard let recvFn = _wsaExtensions.recv else { return nil }
    #endif
    return withDatagramReceive(capacity: capacity) { packet, control, sa, saLen in
      #if canImport(WinSDK)
      var wsabuf = WSABUF(
        len: ULONG(packet.count),
        buf: packet.baseAddress?.assumingMemoryBound(to: CChar.self)
      )
      return withUnsafeMutablePointer(to: &wsabuf) { bufP in
        var msg = WSAMSG()
        msg.name = sa
        msg.namelen = INT(saLen)
        msg.lpBuffers = bufP
        msg.dwBufferCount = 1
        msg.Control = WSABUF(
          len: ULONG(control.count),
          buf: control.baseAddress?.assumingMemoryBound(to: CChar.self)
        )
        msg.dwFlags = 0
        var received: DWORD = 0
        guard recvFn(fd, &msg, &received, nil, nil) == 0 else { return (0, nil) }
        let ctl = UnsafeRawBufferPointer(start: control.baseAddress, count: Int(msg.Control.len))
        return (Int(received), Cmsg.firstPktInfo(in: ctl))
      }
      #else
      var iov = iovec(iov_base: packet.baseAddress, iov_len: packet.count)
      return withUnsafeMutablePointer(to: &iov) { iovP in
        var msg = msghdr()
        msg.msg_name = UnsafeMutableRawPointer(sa)
        msg.msg_namelen = saLen
        msg.msg_iov = iovP
        msg.msg_iovlen = 1
        msg.msg_control = control.baseAddress
        msg.msg_controllen = .init(control.count)
        msg.msg_flags = 0
        let len = recvmsg(fd, &msg, 0)
        guard len > 0 else { return (0, nil) }
        let ctl = UnsafeRawBufferPointer(start: control.baseAddress, count: Int(msg.msg_controllen))
        return (len, Cmsg.firstPktInfo(in: ctl))
      }
      #endif
    }
  }

  // MARK: - Raw fd helpers

  /// Close a raw fd silently. For fds whose ownership left a `Socket` via
  /// `detach()` (dispatch-source cancel handlers).
  static func close(_ fd: SocketDescriptor) {
    _ = sysClose(fd)
  }

  static func makeNonBlocking(_ fd: SocketDescriptor) {
    #if canImport(WinSDK)
    var mode: u_long = 1
    _ = ioctlsocket(fd, FIONBIO, &mode)
    #else
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
    #endif
  }

  /// Dotted-quad presentation of an IPv4 address. `s_addr` is in network
  /// byte order, so its bytes in memory order are already the display order
  /// — no `inet_ntop` needed.
  static func format(_ addr: in_addr) -> String {
    withUnsafeBytes(of: addr.s_addr) { $0.map { String($0) }.joined(separator: ".") }
  }

  // MARK: - Platform shims

  // SOCK_STREAM/SOCK_DGRAM are Int32 on Darwin/Windows and CInt enums on glibc.
  #if canImport(Darwin) || canImport(WinSDK)
  static let streamType: Int32 = SOCK_STREAM
  static let datagramType: Int32 = SOCK_DGRAM
  #else
  static let streamType: Int32 = .init(SOCK_STREAM.rawValue)
  static let datagramType: Int32 = .init(SOCK_DGRAM.rawValue)
  #endif
}

// Module-qualified libc calls that collide with Socket member names (and on
// Windows, the differently-named closesocket).
#if canImport(Darwin)
private let sysBind = Darwin.bind
private let sysListen = Darwin.listen
private let sysClose = Darwin.close
private let sysAccept = Darwin.accept
private let sysGetsockname = Darwin.getsockname
#elseif canImport(WinSDK)
private let sysBind = WinSDK.bind
private let sysListen = WinSDK.listen
private let sysClose = WinSDK.closesocket
private let sysAccept = WinSDK.accept
private let sysGetsockname = WinSDK.getsockname
#elseif canImport(Glibc)
private let sysBind = Glibc.bind
private let sysListen = Glibc.listen
private let sysClose = Glibc.close
private let sysAccept = Glibc.accept
private let sysGetsockname = Glibc.getsockname
#endif

#if canImport(WinSDK)
private let IPPROTO_TCP = WinSDK.IPPROTO_TCP.rawValue
#elseif canImport(Glibc)
let IPPROTO_TCP = Int32(Glibc.IPPROTO_TCP)
let IPPROTO_IP = Int32(Glibc.IPPROTO_IP)
#endif

/// Errno value of the last socket operation.
var errno: Int32 {
  #if canImport(Darwin)
  return Darwin.errno
  #elseif canImport(WinSDK)
  return WSAGetLastError()
  #else
  return Glibc.errno
  #endif
}

/// True if `err` indicates a non-blocking socket would have blocked.
@inline(__always)
func errWouldBlock(_ err: Int32) -> Bool {
  #if canImport(WinSDK)
  return err == WSAEWOULDBLOCK
  #else
  return err == EAGAIN || err == EWOULDBLOCK
  #endif
}

/// True if `err` indicates the operation was interrupted and should retry.
@inline(__always)
func errInterrupted(_ err: Int32) -> Bool {
  #if canImport(WinSDK)
  return err == WSAEINTR
  #else
  return err == EINTR
  #endif
}

/// Human-readable message for a socket error code — `strerror` on POSIX,
/// `FormatMessageW` on Windows (Winsock error codes are Win32 system errors).
func errnoToString(_ err: Int32) -> String {
  #if canImport(WinSDK)
  var buffer: LPWSTR?
  let flags = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER)
    | DWORD(FORMAT_MESSAGE_FROM_SYSTEM)
    | DWORD(FORMAT_MESSAGE_IGNORE_INSERTS)
  // With ALLOCATE_BUFFER, lpBuffer is really a PWSTR* in LPWSTR clothing.
  let length = withUnsafeMutablePointer(to: &buffer) { p in
    p.withMemoryRebound(to: WCHAR.self, capacity: 1) { wp in
      FormatMessageW(flags, nil, DWORD(bitPattern: err), 0, wp, 0, nil)
    }
  }
  guard length > 0, let buffer else { return "Winsock error \(err)" }
  defer { LocalFree(buffer) }
  var message = String(decodingCString: buffer, as: UTF16.self)
  while let last = message.last, last.isWhitespace || last.isNewline {
    message.removeLast()
  }
  return message
  #else
  return String(cString: strerror(err))
  #endif
}

extension sockaddr_in {
  /// Run `body` with this address rebound to the `sockaddr` pointer/length
  /// pair every sockets API wants — the rebinding dance, written once.
  mutating func withSockaddr<R>(
    _ body: (UnsafeMutablePointer<sockaddr>, socklen_t) throws -> R
  ) rethrows -> R {
    try withUnsafeMutablePointer(to: &self) { sp in
      try sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        try body(sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }
}

// MARK: - Windows SOCKET helpers and WSA datagram I/O

#if canImport(WinSDK)
// `SIO_GET_EXTENSION_FUNCTION_POINTER` is a C macro WinSDK doesn't surface.
private let _sioGetExtensionFnPtr: DWORD = 0xC800_0006

private func _loadWSAFn<T>(_ fd: SOCKET, _ guid: GUID) -> T? {
  var g = guid
  var fn: T?
  var returned: DWORD = 0
  let rc = withUnsafeMutablePointer(to: &fn) { p in
    WSAIoctl(
      fd, _sioGetExtensionFnPtr,
      &g, DWORD(MemoryLayout<GUID>.size),
      UnsafeMutableRawPointer(p), DWORD(MemoryLayout<T>.size),
      &returned, nil, nil
    )
  }
  return rc == 0 ? fn : nil
}

// The WSASendMsg/WSARecvMsg pointers are provider-global, so load them once
// (via a throwaway socket) in a lazily-initialized global — Swift guarantees
// the initializer runs exactly once, thread-safely, with no extra lock.
private let _wsaExtensions: (send: LPFN_WSASENDMSG?, recv: LPFN_WSARECVMSG?) = {
  _ensureWinsock()
  let probe = socket(AF_INET, Int32(SOCK_DGRAM), 0)
  guard probe != INVALID_SOCKET else { return (nil, nil) }
  defer { closesocket(probe) }
  return (
    _loadWSAFn(probe, WSAID_WSASENDMSG),
    _loadWSAFn(probe, WSAID_WSARECVMSG)
  )
}()

extension Socket {
  /// Raw socket read (`recv`) — used by the TCP peer read path in place of
  /// POSIX `read`, which on Windows operates on CRT fds, not SOCKETs.
  static func recvRaw(_ fd: SocketDescriptor, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    Int(recv(fd, buf?.assumingMemoryBound(to: CChar.self), Int32(count), 0))
  }

  /// Raw socket write (`send`) — TCP peer write path counterpart of `recvRaw`.
  static func sendRaw(_ fd: SocketDescriptor, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
    Int(WinSDK.send(fd, buf?.assumingMemoryBound(to: CChar.self), Int32(count), 0))
  }
}
#else
extension Socket {
  /// Raw read on POSIX is just `read(2)`.
  static func recvRaw(_ fd: SocketDescriptor, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buf, count)
  }

  /// Raw write on POSIX is just `write(2)`.
  static func sendRaw(_ fd: SocketDescriptor, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buf, count)
  }
}
#endif
