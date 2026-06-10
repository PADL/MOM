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

/// Library logger. The backend is whatever the application bootstrapped
/// `LoggingSystem` with; wire/protocol diagnostics are logged at `.debug`
/// and enabled by default.
let logger: Logger = {
  var logger = Logger(label: "com.padl.MOM")
  logger.logLevel = .debug
  return logger
}()

/// Render wire bytes for logging (they are ASCII). Interior CRs are rendered
/// as newlines so a multi-message buffer reads line-by-line, but the trailing
/// record terminator is trimmed so it doesn't break the surrounding log line.
func wireDescription(_ bytes: some Sequence<UInt8>) -> String {
  var out = ""
  for byte in bytes {
    out.append(byte == 0x0D ? "\n" : Character(UnicodeScalar(byte)))
  }
  while out.hasSuffix("\n") {
    out.removeLast()
  }
  return out
}
