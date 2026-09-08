//
//  ImportPacingTests.swift
//  LumeTests
//
//  The import's thermal valve is only checkable with its inputs stubbed: a
//  simulator never reports anything but `.nominal`, and neither
//  `ProcessInfo.thermalState` nor `isLowPowerModeEnabled` is settable.
//

import Foundation
@testable import Lume
import Testing

private func pause(_ state: ProcessInfo.ThermalState, lowPower: Bool) -> Duration {
    ImportPacing.pauseBetweenBatches(thermalState: state, isLowPower: lowPower)
}

struct ImportPacingTests {
    /// The whole point of the valve: a device that is coping pays nothing, so
    /// the nominal import — and every benchmark of it — runs flat out.
    @Test func `nominal and fair run with no delay`() {
        #expect(pause(.nominal, lowPower: false) == .zero)
        #expect(pause(.fair, lowPower: false) == .zero)
    }

    @Test func `low power mode pauses even on a cool device`() {
        #expect(pause(.nominal, lowPower: true) > .zero)
        #expect(pause(.fair, lowPower: true) > .zero)
    }

    @Test func `thermal pressure pauses regardless of low power mode`() {
        #expect(pause(.serious, lowPower: false) > .zero)
        #expect(pause(.critical, lowPower: false) > .zero)
        #expect(pause(.serious, lowPower: true) > .zero)
        #expect(pause(.critical, lowPower: true) > .zero)
    }

    /// All eight combinations, ordered by how much trouble the device is in.
    /// Non-decreasing rather than strictly increasing because `.nominal` and
    /// `.fair` are deliberately the same thermally — neither contributes.
    ///
    /// Four of the eight are unreachable on tvOS and visionOS, where
    /// `isLowPowerModeEnabled` is always `false`: the ladder pins the policy,
    /// not what any one platform can actually reach.
    @Test func `pauses escalate monotonically with pressure`() {
        let ladder: [Duration] = [
            pause(.nominal, lowPower: false),
            pause(.fair, lowPower: false),
            pause(.nominal, lowPower: true),
            pause(.fair, lowPower: true),
            pause(.serious, lowPower: false),
            pause(.serious, lowPower: true),
            pause(.critical, lowPower: false),
            pause(.critical, lowPower: true)
        ]

        for (earlier, later) in zip(ladder, ladder.dropFirst()) {
            #expect(earlier <= later)
        }
        #expect(ladder.first == .zero)
        #expect(ladder.last == ImportPacing.criticalThermalPause + ImportPacing.lowPowerPause)
    }

    /// Escalation has to be a real step, not a rounding difference: `.critical`
    /// must cost strictly more than `.serious`, which must cost strictly more
    /// than Low Power Mode alone.
    @Test func `each escalation step is strict`() {
        #expect(pause(.nominal, lowPower: true) < pause(.serious, lowPower: false))
        #expect(pause(.serious, lowPower: false) < pause(.serious, lowPower: true))
        #expect(pause(.serious, lowPower: true) < pause(.critical, lowPower: false))
        #expect(pause(.critical, lowPower: false) < pause(.critical, lowPower: true))
    }
}
