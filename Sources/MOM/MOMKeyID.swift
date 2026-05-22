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

public enum MOMKeyID: Int, Sendable, Hashable {
  case output1 = 1
  case output2
  case output3
  case sourceA
  case sourceB
  case sourceC
  case ref
  case dim
  case talk
  case cut
  case layer
  case external
}
