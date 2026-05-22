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

public typealias MOMSendReply = (
  _ controller: MOMController,
  _ peer: MOMPeerContext,
  _ event: MOMEvent,
  _ status: MOMStatus,
  _ params: [MOMParam]
) -> MOMStatus

public typealias MOMHandler = (
  _ controller: MOMController,
  _ peer: MOMPeerContext,
  _ event: MOMEvent,
  _ params: [MOMParam],
  _ sendReply: MOMSendReply?
) -> MOMStatus

internal enum MOMPortStatus: Int {
  case closed = -1
  case open
  case ready
  case connected
}

internal let kMOMDefaultAliveTime: Int32 = 20

/// Top-level controller for a MOM Surrogate endpoint.
///
/// Callbacks are delivered on the `DispatchQueue` provided at init time.
/// The controller takes a strong reference to the queue and to the handler.
public final class MOMController: @unchecked Sendable {
  internal let queue: DispatchQueue
  internal let handler: MOMHandler

  // Access to these from internal helpers assumes we are already on `queue`.
  internal var _options: MOMOptions
  internal var _aliveTime: Int32 = kMOMDefaultAliveTime
  internal weak var _masterPeer: MOMPeerContext?
  internal var _peerPortStatus: [ObjectIdentifier: MOMPortStatus] = [:]
  internal var _peers: [MOMPeerContext] = []
  internal var _tcpListener: MOMListener?
  internal var _udpDiscovery: MOMDiscovery?
  internal var _expiryTimer: DispatchSourceTimer?

  /// Resolved IPv4 addresses for `options.restrictToSpecifiedHost`.
  /// Empty when there is no restriction OR resolution has not yet succeeded.
  /// Mutated only on `queue`.
  internal var _restrictAddresses: [in_addr_t] = []

  public init(
    options: MOMOptions = MOMOptions(),
    queue: DispatchQueue,
    handler: @escaping MOMHandler
  ) {
    self._options = options
    self.queue = queue
    self.handler = handler

    // Resolve a hostname-style host restriction up-front. IPv4 literals
    // resolve essentially for free; hostnames may block briefly on DNS.
    if let host = options.restrictToSpecifiedHost {
      self._restrictAddresses = MOMResolver.resolveIPv4(host)
    }
  }

  /// Re-run DNS resolution for `options.restrictToSpecifiedHost`.
  ///
  /// Dispatches the (potentially blocking) `getaddrinfo` to a utility queue
  /// and updates the cache on `queue` when it completes. Call this if you
  /// suspect the restriction host's DNS has changed since init.
  public func refreshHostRestriction() {
    guard let host = options.restrictToSpecifiedHost else {
      queue.sync { _restrictAddresses = [] }
      return
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let resolved = MOMResolver.resolveIPv4(host)
      guard let strong = self else { return }
      strong.queue.async { strong._restrictAddresses = resolved }
    }
  }

  /// `true` if `peer` is allowed under the current host restriction.
  /// Returns `true` unconditionally when no restriction is configured.
  internal func _peerAddressAllowed(_ peer: in_addr) -> Bool {
    if _options.restrictToSpecifiedHost == nil { return true }
    return _restrictAddresses.contains(peer.s_addr)
  }

  public var options: MOMOptions {
    queue.sync { _options }
  }

  /// Atomically mutate the options. Must NOT be called from inside the
  /// controller's `queue` (would deadlock); use `_updateOptions` internally.
  public func updateOptions(_ mutate: (inout MOMOptions) -> Void) {
    queue.sync { mutate(&_options) }
  }

  // MARK: - Stubs (filled in by later phases)

  public func notify(_ event: MOMEvent, params: [MOMParam] = []) -> MOMStatus {
    // With DispatchSourceWrite, enqueue resumes the source — bytes flush
    // asynchronously. No separate "send" step is needed.
    queue.sync { _enqueueNotification(event, params: params) }
  }

  public func notifyDeferred(_ event: MOMEvent, params: [MOMParam] = []) -> MOMStatus {
    queue.sync { _enqueueNotification(event, params: params) }
  }

  /// No-op in this implementation: `DispatchSourceWrite` flushes the
  /// per-peer write buffer automatically when there is data. Preserved for
  /// API parity with the C surface.
  public func sendDeferred() -> MOMStatus {
    .success
  }

  /// Encode `event | .typeDeviceNotification` and queue it for every peer.
  /// Returns `.socketError` if there are no peers. Caller must be on `queue`.
  @discardableResult
  private func _enqueueNotification(_ event: MOMEvent,
                                    params: [MOMParam]) -> MOMStatus {
    if _peers.isEmpty { return .socketError }
    guard let data = MOMMessage.encode(event.event | .typeDeviceNotification,
                                       params: params)
    else { return .noMemory }
    for peer in _peers {
      _enqueueMessage(peer, data)
    }
    return .success
  }

  public func beginDiscoverability() -> MOMStatus {
    queue.sync {
      guard _tcpListener == nil, _udpDiscovery == nil else {
        return .invalidParameter
      }
      let bindAddr = _options.localInterfaceAddress?.sin_addr.s_addr ?? INADDR_ANY
      guard let tcp = MOMListener.bind(on: MOMPort.control,
                                       address: bindAddr,
                                       controller: self),
            let udp = MOMDiscovery.bind(controller: self)
      else {
        _tcpListener?.invalidate(); _tcpListener = nil
        _udpDiscovery?.invalidate(); _udpDiscovery = nil
        return .socketError
      }
      _tcpListener = tcp
      _udpDiscovery = udp
      return .success
    }
  }

  public func endDiscoverability() -> MOMStatus {
    queue.sync {
      _tcpListener?.invalidate(); _tcpListener = nil
      _udpDiscovery?.invalidate(); _udpDiscovery = nil
      _setMasterPeer(nil)
      for peer in _peers { MOMPeer.close(peer, error: nil) }
      _peers.removeAll()
      return .success
    }
  }

  /// Broadcast an unsolicited discovery notification.
  ///
  /// With `options.restrictToSpecifiedHost` set, the announcement is
  /// unicast to every resolved IPv4 address for that host. Otherwise it is
  /// broadcast on every up-and-running IPv4 interface (optionally filtered
  /// by `options.localInterfaceAddress`).
  public func announceDiscoverability() -> MOMStatus {
    queue.sync {
      guard let discovery = _udpDiscovery else { return .invalidParameter }

      if _options.restrictToSpecifiedHost != nil {
        if _restrictAddresses.isEmpty { return .socketError }   // unresolved
        for addr in _restrictAddresses {
          discovery.announce(controller: self, unicastTo: addr)
        }
      } else {
        discovery.announce(controller: self, unicastTo: nil)
      }
      return .success
    }
  }

  // MARK: - Internal hooks used by built-in handlers
  //
  // These assume the caller is already on `queue`. Phase 5 fills in master
  // tracking and the alive-time expiry timer.

  internal func _isPeerMaster(_ peer: MOMPeerContext) -> Bool {
    _masterPeer === peer
  }

  internal func _setMasterPeer(_ peer: MOMPeerContext?) {
    _masterPeer = peer
  }

  internal func _peerPortStatus(_ peer: MOMPeerContext) -> MOMPortStatus {
    _peerPortStatus[ObjectIdentifier(peer)] ?? .closed
  }

  internal func _setPeerPortStatus(_ peer: MOMPeerContext, _ status: MOMPortStatus) {
    _peerPortStatus[ObjectIdentifier(peer)] = status
  }

  /// Validates and sets the per-peer keep-alive interval (1...60 seconds).
  /// (Re-)arms the expiry timer.
  @discardableResult
  internal func _setAliveTime(_ value: Int32) -> Bool {
    if value == _aliveTime && _expiryTimer != nil { return true }
    guard (1...60).contains(value) else { return false }
    _aliveTime = value

    _expiryTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Double(value),
                   repeating: Double(value))
    timer.setEventHandler { [weak self] in
      self?._expireStalePeers()
    }
    timer.resume()
    _expiryTimer = timer
    return true
  }

  /// Drop any peer whose last activity is older than `aliveTime` seconds.
  /// Caller must be on `queue`.
  internal func _expireStalePeers() {
    let now = time(nil)
    let aliveSeconds = time_t(_aliveTime)
    let stale = _peers.filter { p in
      p.lastActivity != 0 && p.lastActivity + aliveSeconds < now
    }
    for p in stale {
      MOMPeer.close(p, error: nil)
    }
  }

  // MARK: - Enqueue for send

  /// Test-only hook overriding the real TCP write. When set, the data is
  /// captured here instead of being queued onto the peer's write source.
  internal var _sendHook: ((MOMPeerContext, Data) -> Void)?

  internal func _enqueueMessage(_ peer: MOMPeerContext, _ data: Data) {
    if let hook = _sendHook { hook(peer, data); return }
    MOMPeer.enqueue(peer, data)
  }

  // MARK: - Peer list (mutated only on `queue`)

  internal func _addPeer(_ peer: MOMPeerContext) {
    _peers.append(peer)
  }

  internal func _removePeer(_ peer: MOMPeerContext) {
    _peers.removeAll { $0 === peer }
    _peerPortStatus.removeValue(forKey: ObjectIdentifier(peer))
  }

  /// Send the application handler a port-state-change notification. The
  /// matching `MOMEvent.port*` value is derived from `status`.
  internal func _notifyPortState(_ peer: MOMPeerContext,
                                 status: MOMPortStatus,
                                 error: Int32? = nil) {
    let event: MOMEvent
    switch status {
    case .closed:    event = error != nil ? .portError : .portClosed
    case .open:      event = .portOpen
    case .ready:     event = .portReady
    case .connected: event = .portConnected
    }
    var params: [MOMParam] = [.string(peer.peerName ?? "")]
    if let err = error { params.append(.int(err)) }
    _ = handler(self, peer, event, params, nil)
  }

  // MARK: - Process an incoming event (called from peer I/O on `queue`)

  /// Dispatches `eventWithType` through the built-in handler table and, if
  /// appropriate, the application handler. Sends replies for host requests
  /// via `_enqueueMessage`.
  ///
  /// Assumes the caller is already on `queue`.
  @discardableResult
  internal func _processEvent(
    peer: MOMPeerContext,
    eventWithType: MOMEvent,
    params: [MOMParam]
  ) -> MOMStatus {
    let event = eventWithType.event
    let type = eventWithType.type

    precondition(type.rawValue & MOMEvent.typeHostAny.rawValue != 0,
                 "process only host-side messages")
    precondition(type.rawValue & MOMEvent.typeDeviceAny.rawValue == 0)
    precondition(event != .none && event.rawValue <= MOMEvent.max.rawValue)

    var replyParams = params

    if !_isPeerMaster(peer) && !MOMHandlers.isValidOnNonMaster(eventWithType) {
      return .requiresMaster
    }

    guard let entry = MOMHandlers.table[event],
          entry.validTypes.rawValue & type.rawValue != 0
    else { return .invalidRequest }

    var status: MOMStatus = .continue

    if let builtin = entry.handler {
      status = builtin(self, peer, eventWithType, &replyParams)
      if status != .continue, eventWithType.isHostRequest {
        sendReply(peer: peer, eventWithType: eventWithType,
                  status: status, params: replyParams)
        return .success
      }
    }

    if status == .continue {
      if eventWithType.isHostRequest {
        let sender: MOMSendReply = { controller, peer, event, status, params in
          controller.sendReply(peer: peer, eventWithType: event,
                               status: status, params: params)
          return .success
        }
        status = handler(self, peer, eventWithType, replyParams, sender)
      } else {
        status = handler(self, peer, eventWithType, replyParams, nil)
      }
    }

    if status == .continue { status = .invalidRequest }
    return status
  }

  private func sendReply(peer: MOMPeerContext,
                         eventWithType: MOMEvent,
                         status: MOMStatus,
                         params: [MOMParam]) {
    var reply = params
    reply.insert(.int(Int32(status.rawValue)), at: 0)
    guard let data = MOMMessage.encode(eventWithType.event | .typeDeviceReply,
                                       params: reply)
    else { return }
    _enqueueMessage(peer, data)
  }
}
