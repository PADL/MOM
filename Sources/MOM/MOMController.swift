//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import Dispatch
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public typealias MOMSendReply = (
  _ controller: MOMController,
  _ peer: MOMPeerContext,
  _ event: MOMEvent,
  _ status: MOMStatus,
  _ params: [MOMParameter]
) -> MOMStatus

public typealias MOMHandler = (
  _ controller: MOMController,
  _ peer: MOMPeerContext,
  _ event: MOMEvent,
  _ params: [MOMParameter],
  _ sendReply: MOMSendReply?
) -> MOMStatus

enum MOMPortStatus: Int {
  case closed = -1
  case open
  case ready
  case connected
}

let kMOMDefaultAliveTime: Int32 = 20

/// Top-level controller for a MOM Surrogate endpoint.
///
/// Callbacks are delivered on the `DispatchQueue` provided at init time.
/// The controller takes a strong reference to the queue and to the handler.
public final class MOMController: @unchecked Sendable {
  let queue: DispatchQueue
  let handler: MOMHandler

  /// Unique per-controller marker set on `queue`, so public APIs can detect
  /// re-entrant calls from inside handler callbacks (which run on `queue`)
  /// and execute inline instead of deadlocking in `queue.sync`. The C API
  /// allowed handlers to call back into the controller; so do we.
  private let queueKey = DispatchSpecificKey<()>()

  // Access to these from internal helpers assumes we are already on `queue`.
  var _options: MOMOptions
  var _aliveTime: Int32 = kMOMDefaultAliveTime
  weak var _masterPeer: MOMPeerContext?
  var _peers: [MOMPeerContext] = []
  var _tcpListener: MOMListener?
  var _udpDiscovery: MOMDiscovery?
  var _expiryTimer: DispatchSourceTimer?

  /// Resolved IPv4 addresses for `options.restrictToSpecifiedHost`.
  /// Empty when there is no restriction OR resolution has not yet succeeded.
  /// Mutated only on `queue`.
  var _restrictAddresses: [in_addr_t] = []

  /// Local interface the listening/discovery sockets bind to (nil →
  /// INADDR_ANY). This is transient network state rather than persisted
  /// configuration, so it lives here instead of in `MOMOptions`. Mutated
  /// only on `queue`.
  var _localInterfaceAddress: sockaddr_in?

  public init(
    options: MOMOptions = MOMOptions(),
    queue: DispatchQueue,
    handler: @escaping MOMHandler
  ) {
    _options = options
    self.queue = queue
    self.handler = handler
    queue.setSpecific(key: queueKey, value: ())

    // Resolve a hostname-style host restriction up-front. IPv4 literals
    // resolve essentially for free; hostnames may block briefly on DNS.
    if let host = options.restrictToSpecifiedHost {
      _restrictAddresses = MOMResolver.resolveIPv4(host)
    }

    // Arm the peer-expiry timer from creation (C parity: a peer that
    // connects and dies without ever sending salivetime must still expire).
    _setAliveTime(kMOMDefaultAliveTime)
  }

  deinit {
    _expiryTimer?.cancel()
    // Listener/discovery/peer teardown is handled by their own deinits:
    // each cancels its dispatch sources, whose cancel handlers close the fds.
  }

  /// Run `body` on `queue`, inline when already there (re-entrant safe).
  func withQueue<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try body()
    }
    return try queue.sync(execute: body)
  }

  /// Re-run DNS resolution for `options.restrictToSpecifiedHost`.
  ///
  /// Dispatches the (potentially blocking) `getaddrinfo` to a utility queue
  /// and updates the cache on `queue` when it completes. Call this if you
  /// suspect the restriction host's DNS has changed since init.
  public func refreshHostRestriction() {
    guard let host = options.restrictToSpecifiedHost else {
      withQueue { _restrictAddresses = [] }
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
  func _peerAddressAllowed(_ peer: in_addr) -> Bool {
    if _options.restrictToSpecifiedHost == nil { return true }
    return _restrictAddresses.contains(peer.s_addr)
  }

  public var options: MOMOptions {
    withQueue { _options }
  }

  /// The local interface the sockets bind to, or nil for INADDR_ANY. Transient
  /// network state (not part of `MOMOptions`); set before `beginDiscoverability`.
  public var localInterfaceAddress: sockaddr_in? {
    get { withQueue { _localInterfaceAddress } }
    set { withQueue { _localInterfaceAddress = newValue } }
  }

  /// Atomically mutate the options. Safe to call from handler callbacks.
  public func updateOptions(_ mutate: (inout MOMOptions) -> ()) {
    withQueue { mutate(&_options) }
  }

  // MARK: - Notifications

  /// Encode `event | .typeDeviceNotification` and queue it for every peer.
  /// Bytes flush asynchronously via each peer's write source. Safe to call
  /// from handler callbacks.
  public func notify(_ event: MOMEvent, params: [MOMParameter] = []) -> MOMStatus {
    withQueue { _enqueueNotification(event, params: params) }
  }

  /// Encode `event | .typeDeviceNotification` and queue it for every peer.
  /// Returns `.socketError` if there are no peers. Caller must be on `queue`.
  @discardableResult
  private func _enqueueNotification(
    _ event: MOMEvent,
    params: [MOMParameter]
  ) -> MOMStatus {
    if _peers.isEmpty { return .socketError }
    guard let data = MOMMessage.encode(
      event.event | .typeDeviceNotification,
      params: params
    )
    else { return .noMemory }
    for peer in _peers {
      _enqueueMessage(peer, data)
    }
    return .success
  }

  /// Bind the control listener and discovery socket, then broadcast the
  /// initial discovery announcement (C parity: a device announces itself as
  /// soon as it becomes discoverable). Fails — releasing both sockets — if
  /// any step fails.
  public func beginDiscoverability() -> MOMStatus {
    withQueue {
      guard _tcpListener == nil, _udpDiscovery == nil else {
        return .invalidParameter
      }
      let bindAddr = _localInterfaceAddress?.sin_addr.s_addr ?? INADDR_ANY
      guard let tcp = MOMListener.bind(
        on: MOMPort.control,
        address: bindAddr,
        controller: self
      ),
        let udp = MOMDiscovery.bind(controller: self)
      else {
        // A successfully-bound guard local is torn down by its deinit.
        return .socketError
      }
      _tcpListener = tcp
      _udpDiscovery = udp

      let status = _announceDiscoverability()
      if status != .success {
        _tcpListener?.invalidate(); _tcpListener = nil
        _udpDiscovery?.invalidate(); _udpDiscovery = nil
      }
      return status
    }
  }

  public func endDiscoverability() -> MOMStatus {
    withQueue {
      _tcpListener?.invalidate(); _tcpListener = nil
      _udpDiscovery?.invalidate(); _udpDiscovery = nil
      _setMasterPeer(nil)
      for peer in _peers {
        MOMPeer.close(peer, error: nil)
      }
      _peers.removeAll()
      return .success
    }
  }

  /// Broadcast an unsolicited discovery notification.
  ///
  /// With `options.restrictToSpecifiedHost` set, the announcement is
  /// unicast to every resolved IPv4 address for that host. Otherwise it is
  /// broadcast on every up-and-running IPv4 interface (optionally filtered
  /// by `localInterfaceAddress`).
  public func announceDiscoverability() -> MOMStatus {
    withQueue { _announceDiscoverability() }
  }

  /// On-queue body of `announceDiscoverability`.
  private func _announceDiscoverability() -> MOMStatus {
    guard let discovery = _udpDiscovery else { return .invalidParameter }

    if _options.restrictToSpecifiedHost != nil {
      if _restrictAddresses.isEmpty { return .socketError } // unresolved
      for addr in _restrictAddresses {
        discovery.announce(controller: self, unicastTo: addr)
      }
    } else {
      discovery.announce(controller: self, unicastTo: nil)
    }
    return .success
  }

  // MARK: - Internal hooks used by built-in handlers

  //
  // These assume the caller is already on `queue`. Phase 5 fills in master
  // tracking and the alive-time expiry timer.

  func _isPeerMaster(_ peer: MOMPeerContext) -> Bool {
    _masterPeer === peer
  }

  func _setMasterPeer(_ peer: MOMPeerContext?) {
    _masterPeer = peer
  }

  func _peerPortStatus(_ peer: MOMPeerContext) -> MOMPortStatus {
    peer.portStatus
  }

  /// Record the peer's port status and notify the application handler with
  /// the matching `.port*` event (C parity: `_MOMSetPeerPortStatus` always
  /// invoked the handler — clients like MOMOCABridge track connection state
  /// from these events).
  func _setPeerPortStatus(
    _ peer: MOMPeerContext,
    _ status: MOMPortStatus,
    error: Int32? = nil
  ) {
    peer.portStatus = status
    logger.debug("peer \(peer.peerName ?? "?") port status -> \(status)")
    _notifyPortState(peer, status: status, error: error)
  }

  /// Validates and sets the per-peer keep-alive interval (1...60 seconds).
  /// (Re-)arms the expiry timer.
  @discardableResult
  func _setAliveTime(_ value: Int32) -> Bool {
    if value == _aliveTime && _expiryTimer != nil { return true }
    guard (1...60).contains(value) else { return false }
    _aliveTime = value

    _expiryTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + Double(value),
      repeating: Double(value)
    )
    timer.setEventHandler { [weak self] in
      self?._expireStalePeers()
    }
    timer.resume()
    _expiryTimer = timer
    return true
  }

  /// Drop any peer whose last activity is older than `aliveTime` seconds.
  /// Caller must be on `queue`.
  func _expireStalePeers() {
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
  var _sendHook: ((MOMPeerContext, Data) -> ())?

  func _enqueueMessage(_ peer: MOMPeerContext, _ data: Data) {
    // Match the C library: log queued traffic except keep-alive noise.
    if !data.starts(with: Data(":aliverequest".utf8)) {
      logger.debug("queued message \(wireDescription(data)) for \(peer.peerName ?? "?")")
    }
    if let hook = _sendHook { hook(peer, data); return }
    MOMPeer.enqueue(peer, data)
  }

  // MARK: - Peer list (mutated only on `queue`)

  func _addPeer(_ peer: MOMPeerContext) {
    _peers.append(peer)
  }

  func _removePeer(_ peer: MOMPeerContext) {
    _peers.removeAll { $0 === peer }
  }

  /// Send the application handler a port-state-change notification. The
  /// matching `MOMEvent.port*` value is derived from `status`.
  func _notifyPortState(
    _ peer: MOMPeerContext,
    status: MOMPortStatus,
    error: Int32? = nil
  ) {
    let event: MOMEvent = switch status {
    case .closed: error != nil ? .portError : .portClosed
    case .open: .portOpen
    case .ready: .portReady
    case .connected: .portConnected
    }
    var params: [MOMParameter] = [.string(peer.peerName ?? "")]
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
  func _processEvent(
    peer: MOMPeerContext,
    eventWithType: MOMEvent,
    params: [MOMParameter]
  ) -> MOMStatus {
    let event = eventWithType.event
    let type = eventWithType.type

    precondition(
      type.rawValue & MOMEvent.typeHostAny.rawValue != 0,
      "process only host-side messages"
    )
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
        sendReply(
          peer: peer,
          eventWithType: eventWithType,
          status: status,
          params: replyParams
        )
        return .success
      }
    }

    if status == .continue {
      if eventWithType.isHostRequest {
        // The sender may be invoked later, from any thread or task (async
        // clients reply after the handler returns), so hop to the queue.
        let sender: MOMSendReply = { controller, peer, event, status, params in
          controller.withQueue {
            controller.sendReply(
              peer: peer,
              eventWithType: event,
              status: status,
              params: params
            )
          }
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

  private func sendReply(
    peer: MOMPeerContext,
    eventWithType: MOMEvent,
    status: MOMStatus,
    params: [MOMParameter]
  ) {
    var reply = params
    reply.insert(.int(Int32(status.rawValue)), at: 0)
    guard let data = MOMMessage.encode(
      eventWithType.event | .typeDeviceReply,
      params: reply
    )
    else { return }
    _enqueueMessage(peer, data)
  }
}
