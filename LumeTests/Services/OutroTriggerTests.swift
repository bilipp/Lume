//
//  OutroTriggerTests.swift
//  LumeTests
//
//  Covers `OutroTrigger.armTime`: the unknown-duration guard, every sanity
//  check that rejects IntroDB data which doesn't match the provider's encode,
//  and the `max()` clamp that keeps the button from ever arming before the
//  legacy 90% line.
//

import Foundation
@testable import Lume
import Testing

struct OutroTriggerTests {
    private let duration: TimeInterval = 1000

    @Test func `no outro falls back to fraction`() {
        #expect(OutroTrigger.armTime(outro: nil, duration: duration) == 900)
    }

    @Test func `unknown duration returns nil`() {
        #expect(OutroTrigger.armTime(outro: nil, duration: 0) == nil)
        #expect(OutroTrigger.armTime(outro: nil, duration: 1) == nil)
        #expect(
            OutroTrigger.armTime(
                outro: IntroSegments.Segment(start: 960, end: 1000),
                duration: 1
            ) == nil
        )
    }

    @Test func `outro shorter than floor falls back`() {
        let outro = IntroSegments.Segment(start: 960, end: 963)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `outro starting at zero falls back`() {
        let outro = IntroSegments.Segment(start: 0, end: 60)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `outro beyond duration falls back`() {
        let outro = IntroSegments.Segment(start: 1200, end: 1260)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `outro ending far from duration falls back`() {
        // Third-party data for a different encode: credits "end" 400s before
        // this file does.
        let outro = IntroSegments.Segment(start: 540, end: 600)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `late outro arms at outro start`() {
        let outro = IntroSegments.Segment(start: 960, end: 1000)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 960)
    }

    @Test func `early outro is clamped to the fallback line`() {
        // The single most important case: an outro that starts at 80% must not
        // arm the button below the 90% watched-completion threshold.
        let outro = IntroSegments.Segment(start: 800, end: 1000)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `end slack boundary is inclusive`() {
        let atLimit = IntroSegments.Segment(start: 905, end: 910)
        #expect(OutroTrigger.armTime(outro: atLimit, duration: duration) == 905)

        let pastLimit = IntroSegments.Segment(start: 904, end: 909)
        #expect(OutroTrigger.armTime(outro: pastLimit, duration: duration) == 900)
    }

    @Test func `outro running past the end of the encode falls back`() {
        // A window timed against a longer cut than the one playing: the end
        // slack is negative, which must not sneak through the `<= maxEndSlack`
        // check. Without the overshoot bound this armed at 950.
        let longerCut = IntroSegments.Segment(start: 950, end: 3000)
        #expect(OutroTrigger.armTime(outro: longerCut, duration: duration) == 900)
    }

    @Test func `outro overshooting by rounding is still trusted`() {
        // A second or two past the reported duration is ordinary rounding
        // between the container and the engine, not a mismatched encode.
        let rounding = IntroSegments.Segment(start: 950, end: 1001)
        #expect(OutroTrigger.armTime(outro: rounding, duration: duration) == 950)
    }
}
