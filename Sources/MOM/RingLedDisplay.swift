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

public struct RingLedDisplay {
    public enum LedColor: Int {
        case off = 0, green, red, orange
    }

    // lookup table enumerates the states a LED pair can be
    private static let LedLut = [
        (LedColor.red, LedColor.off),
        (LedColor.orange, LedColor.green),
        (LedColor.orange, LedColor.orange),
        (LedColor.green, LedColor.orange),
    ]
    public static let LedCount = 27
    public static let LedSteps = (LedCount - 1) * LedLut.count

    private var ledState = [LedColor](repeating: LedColor.off, count: LedCount)

    public init() {}

    // this returns an optional as there are some invalid states whilst the
    // virtual ring led display is being updated which should be ignored
    public var value: Int? {
        var interpolatedValue: Int?

        for i in 0...ledState.count - 1 {
            var ringLedPair = (
                ledState[i],
                i == ledState.count - 1 ? LedColor.off : ledState[i + 1]
            )

            if i == 0 && ringLedPair.0 == LedColor.orange && ringLedPair.1 == LedColor.off {
                ringLedPair.0 = LedColor.red // Orange is the new Red
            }

            if let lutIndex = RingLedDisplay.LedLut.firstIndex(where: { $0 == ringLedPair }) {
                interpolatedValue = i * RingLedDisplay.LedLut.count + lutIndex
                break
            }
        }

        return interpolatedValue
    }

    public func scaleValue(dB: Float, relativeTo: Float = MOM.dBDadDisplayFloor) -> Float {
        powf((dB - relativeTo) / MOM.dBTotalGain, 2.0)
    }

    public var scaledValue: Float? {
        // DADman allows gain control of -100...+12dB, although only -40...+12dB is
        // represented on the ring led display.
        //
        // In other words, a range of 112dB, of which 52dB is representable here
        // (each of the 104 LED positions thus represents a 0.5dB increment)
        if let interpolatedValue = value {
            let dB = MOM.dBUnrepresentableGain + Float(interpolatedValue) / MOM.dBIncrements

            // scaled to match DADman slider. at least in theory
            return scaleValue(dB: dB, relativeTo: 0.0)
        }

        return nil
    }

    public var dBValue: Decibel? {
        if let value {
            return MOM.dBMomDisplayFloor + Float(value) / MOM.dBIncrements
        }

        return nil
    }

    public mutating func update(led ledNumber: Int, to color: RingLedDisplay.LedColor) {
        precondition(ledNumber <= RingLedDisplay.LedCount)

        ledState[ledNumber - 1] = color
    }

    private static func unscale(_ value: Float) -> Int {
        precondition(value >= 0.0)
        precondition(value <= 1.0)

        // converse of scaledValue(), this calculates the number of LED steps
        // from the slider value, clamping unrepresentable values to 0
        var unscaledValue = MOM
            .dBIncrements * (MOM.dBTotalGain * value.squareRoot() - MOM.dBUnrepresentableGain)

        if unscaledValue < 0 {
            unscaledValue = 0
        }

        return lroundf(unscaledValue)
    }

    public static func colorForScaledValue(led ledNumber: Int, value: Float) -> RingLedDisplay
        .LedColor
    {
        precondition(ledNumber <= RingLedDisplay.LedCount)

        let interpolatedValue = unscale(value)

        if interpolatedValue / ledNumber != 0 {
            let ledIntensity = RingLedDisplay
                .LedLut[interpolatedValue % RingLedDisplay.LedLut.count]

            return ledNumber % 2 != 0 ? ledIntensity.0 : ledIntensity.1
        }

        return LedColor.off
    }

    private static func unscaleDB(_ dBValue: Float) -> Int {
        var dBValue = dBValue

        precondition(dBValue >= MOM.dBDadDisplayFloor)
        precondition(dBValue <= MOM.dBDadDisplayCeiling)

        dBValue -= MOM.dBMomDisplayFloor
        if dBValue < 0 {
            dBValue = 0
        }

        return lroundf(dBValue * MOM.dBIncrements)
    }

    public static func colorForDBValue(led ledNumber: Int, value: Decibel) -> RingLedDisplay
        .LedColor
    {
        precondition(ledNumber <= RingLedDisplay.LedCount)

        let interpolatedValue = unscaleDB(value)

        if interpolatedValue / ledNumber != 0 {
            let ledIntensity = RingLedDisplay
                .LedLut[interpolatedValue % RingLedDisplay.LedLut.count]

            return ledNumber % 2 != 0 ? ledIntensity.0 : ledIntensity.1
        }

        return LedColor.off
    }

    public func colorForLed(led ledNumber: Int) -> RingLedDisplay.LedColor? {
        guard ledNumber >= 0 && ledNumber < Self.LedCount else {
            return nil
        }

        return ledState[ledNumber]
    }
}
