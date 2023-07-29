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

public typealias Decibel = Float

public enum MOM {
    // maximum gain range in DADman (112dB)
    public static let dBTotalGain: Decibel = 112.0

    // increments of gain display supported by ring LED display/rotary encoder (2)
    public static let dBIncrements: Float = 2.0
    // gain representable by ring led display (52dB)
    public static let dBRepresentableGain: Decibel = .init(RingLedDisplay.LedSteps) / dBIncrements
    // gain unrepresentable by ring led display (60dB)
    public static let dBUnrepresentableGain: Decibel = dBTotalGain - dBRepresentableGain

    // minimum gain in DADman (-100dB)
    public static let dBDadDisplayFloor: Decibel = -100.0
    // maximum gain in DADman (+12dB)
    public static let dBDadDisplayCeiling = dBDadDisplayFloor + dBTotalGain

    // minimum gain in MOM (-40dB)
    public static let dBMomDisplayFloor: Decibel = dBDadDisplayFloor + dBUnrepresentableGain
    // maximum gain in MOM (+12dB)
    public static let dBMomDisplayCeiling: Decibel = dBMomDisplayFloor + dBRepresentableGain
}
