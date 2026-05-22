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

public enum MOMStatus: Int, Sendable, Hashable {
  case socketError      = -3
  case noMemory         = -2
  case `continue`       = -1
  case success          = 0
  case invalidRequest   = 1
  case invalidParameter = 2
  case requiresMaster   = 4
}
