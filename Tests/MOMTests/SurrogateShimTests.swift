//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
//

import Foundation
import XCTest
import Surrogate   // legacy module under test

final class SurrogateShimTests: XCTestCase {
  /// `import Surrogate` should re-export every public MOM symbol via
  /// `@_exported import MOM`. If this file builds, the re-export works.
  func testFreeFunctionWrappers() {
    let q = DispatchQueue(label: "shim")
    var opts = MOMOptions(); opts.deviceID = 5; opts.deviceName = "Shim"

    let controller: MOMControllerRef? = MOMControllerCreate(
      nil, opts, q,
      { _, _, _, _, _ in .success })
    XCTAssertNotNil(controller)

    // Retain/release are no-ops but should still type-check.
    let again = MOMControllerRetain(controller!)
    XCTAssertTrue(again === controller!)
    MOMControllerRelease(controller!)

    let fetched = MOMControllerGetOptions(controller!)
    XCTAssertEqual(fetched.deviceID, 5)
    XCTAssertEqual(fetched.deviceName, "Shim")

    // Empty-peer-list notify path.
    XCTAssertEqual(MOMControllerNotify(controller!, .setKeyState, [.int(1)]),
                   .socketError)
    XCTAssertEqual(MOMControllerNotifyDeferred(controller!, .setKeyState, [.int(1)]),
                   .socketError)
    XCTAssertEqual(MOMControllerSendDeferred(controller!), .success)
  }
}
