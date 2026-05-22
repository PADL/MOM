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

/// Helpers for packing/unpacking ancillary control messages around
/// `sendmsg`/`recvmsg`. Replicates the CMSG_* C macros, which Swift can't
/// import.
enum Cmsg {
  // On glibc (Linux), cmsg payloads are aligned to `sizeof(size_t)` = 8 on
  // 64-bit. On Darwin, the macros align to `sizeof(uint32_t)` = 4.
  #if canImport(Darwin)
  static let alignTo = MemoryLayout<UInt32>.stride
  #else
  static let alignTo = MemoryLayout<Int>.stride
  #endif

  @inline(__always)
  static func align(_ n: Int) -> Int {
    (n + alignTo - 1) & ~(alignTo - 1)
  }

  static var cmsgHeaderSize: Int {
    align(MemoryLayout<cmsghdr>.size)
  }

  static func space(_ payload: Int) -> Int {
    align(MemoryLayout<cmsghdr>.size) + align(payload)
  }

  static func length(_ payload: Int) -> Int {
    align(MemoryLayout<cmsghdr>.size) + payload
  }

  /// Walk control-message ancillary data and return the first matching
  /// `IP_PKTINFO`, if any.
  static func firstPktInfo(in control: UnsafeRawBufferPointer) -> in_pktinfo? {
    let hdrSize = MemoryLayout<cmsghdr>.size
    var offset = 0
    while offset + hdrSize <= control.count {
      let hdr = control.baseAddress!.load(fromByteOffset: offset, as: cmsghdr.self)
      let len = Int(hdr.cmsg_len)
      if len < hdrSize || offset + len > control.count { break }
      if hdr.cmsg_level == Int32(IPPROTO_IP), hdr.cmsg_type == IP_PKTINFO {
        let dataOffset = offset + cmsgHeaderSize
        if dataOffset + MemoryLayout<in_pktinfo>.size <= control.count {
          return control.baseAddress!.load(fromByteOffset: dataOffset, as: in_pktinfo.self)
        }
      }
      offset += align(len)
    }
    return nil
  }

  /// Build a `IP_PKTINFO` cmsg into the supplied buffer. Returns the number
  /// of bytes written, or 0 if the buffer is too small.
  @discardableResult
  static func writePktInfo(
    _ pktInfo: in_pktinfo,
    into control: UnsafeMutableRawBufferPointer
  ) -> Int {
    let needed = space(MemoryLayout<in_pktinfo>.size)
    guard control.count >= needed else { return 0 }

    var hdr = cmsghdr()
    // cmsg_len is `Int` on glibc and `socklen_t` on Darwin — assign via a
    // numeric init through the property's own type.
    hdr.cmsg_len = .init(length(MemoryLayout<in_pktinfo>.size))
    hdr.cmsg_level = Int32(IPPROTO_IP)
    hdr.cmsg_type = IP_PKTINFO

    control.baseAddress!.storeBytes(of: hdr, as: cmsghdr.self)
    var pi = pktInfo
    control.baseAddress!.advanced(by: cmsgHeaderSize)
      .copyMemory(from: &pi, byteCount: MemoryLayout<in_pktinfo>.size)
    return needed
  }
}
