//
// Copyright (c) 2018-2023 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

public struct RotaryEncoder {
    private static let Steps = MOM.dBTotalGain * MOM.dBIncrements

    public private(set) var rotationCount: UInt16 = 0

    public init() {}

    private static func unscale(_ value: Float) -> Int {
        precondition(value >= 0.0)
        precondition(value <= 1.0)

        return lroundf(value.squareRoot() * Float(RotaryEncoder.Steps))
    }

    private static func unscaleDB(_ dBValue: Decibel) -> Int {
        precondition(dBValue >= MOM.dBDadDisplayFloor)
        precondition(dBValue <= MOM.dBDadDisplayCeiling)

        let absoluteDBValue: Decibel = dBValue - MOM.dBDadDisplayFloor
        return Int(absoluteDBValue * MOM.dBIncrements)
    }

    public mutating func rotate(by steps: Int) {
        if steps > 0 {
            rotationCount = rotationCount &+ UInt16(steps.magnitude)
        } else {
            rotationCount = rotationCount &- UInt16(steps.magnitude)
        }
    }

    private mutating func rotate(to newValue: Int, from oldValue: Int) {
        rotate(by: newValue - oldValue)
    }

    public mutating func rotateScaled(to newValue: Float, from oldValue: Float) {
        let oldValueUnscaled = RotaryEncoder.unscale(oldValue)
        let newValueUnscaled = RotaryEncoder.unscale(newValue)

        rotate(to: newValueUnscaled, from: oldValueUnscaled)
    }

    public mutating func rotateScaledDB(to newValue: Decibel, from oldValue: Decibel) {
        let oldValueUnscaled = RotaryEncoder.unscaleDB(oldValue)
        let newValueUnscaled = RotaryEncoder.unscaleDB(newValue)

        rotate(to: newValueUnscaled, from: oldValueUnscaled)
    }
}
