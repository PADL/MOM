//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

// Legacy compatibility shim. The MOM controller, options, events and
// related types now live in the MOM module — this target preserves the
// C-style free-function surface for callers that still write
// `import Surrogate` and `MOMControllerCreate(...)` / `MOMControllerNotify(...)`.
//
// New code should `import MOM` and use `MOMController` directly.

@_exported import MOM
import Foundation

// MARK: - Transitional type aliases

/// Historical name from the C header. Resolves to the Swift `MOMController`
/// class. ARC handles its lifetime — calls to `MOMControllerRetain` /
/// `MOMControllerRelease` are no-ops.
public typealias MOMControllerRef = MOMController

// MARK: - Free-function wrappers

@discardableResult
public func MOMControllerCreate(
  _ allocator: AnyObject?,                       // historical; ignored
  _ options: MOMOptions = MOMOptions(),
  _ queue: DispatchQueue,
  _ handler: @escaping MOMHandler
) -> MOMController? {
  MOMController(options: options, queue: queue, handler: handler)
}

public func MOMControllerRetain(_ c: MOMController) -> MOMController { c }
public func MOMControllerRelease(_ c: MOMController) {}

public func MOMControllerGetOptions(_ c: MOMController) -> MOMOptions {
  c.options
}

public func MOMControllerNotify(_ c: MOMController,
                                _ event: MOMEvent,
                                _ params: [MOMParam] = []) -> MOMStatus {
  c.notify(event, params: params)
}

public func MOMControllerNotifyDeferred(_ c: MOMController,
                                        _ event: MOMEvent,
                                        _ params: [MOMParam] = []) -> MOMStatus {
  c.notifyDeferred(event, params: params)
}

public func MOMControllerSendDeferred(_ c: MOMController) -> MOMStatus {
  c.sendDeferred()
}

public func MOMControllerBeginDiscoverability(_ c: MOMController) -> MOMStatus {
  c.beginDiscoverability()
}

public func MOMControllerEndDiscoverability(_ c: MOMController) -> MOMStatus {
  c.endDiscoverability()
}

public func MOMControllerAnnounceDiscoverability(_ c: MOMController) -> MOMStatus {
  c.announceDiscoverability()
}
