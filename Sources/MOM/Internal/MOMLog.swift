//
// Copyright (c) 2018-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import Logging

/// Default library logger, used when the application does not supply its own
/// via `MOMController.init(logger:)`. The backend is whatever the application
/// bootstrapped `LoggingSystem` with; wire/protocol diagnostics are logged at
/// `.debug` and enabled by default.
let defaultLogger: Logger = {
  var logger = Logger(label: "com.padl.MOM")
  logger.logLevel = .debug
  return logger
}()

/// Render wire bytes for logging (they are ASCII). The CR record terminator
/// is shown as a literal `\r` so it separates messages in a multi-message
/// buffer without breaking the surrounding log line.
func wireDescription(_ bytes: some Sequence<UInt8>) -> String {
  var out = ""
  for byte in bytes {
    if byte == 0x0D {
      out.append("\\r")
    } else {
      out.append(Character(UnicodeScalar(byte)))
    }
  }
  return out
}
