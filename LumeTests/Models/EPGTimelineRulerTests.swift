import CoreGraphics
import Foundation
@testable import Lume
import Testing

struct EPGTimelineRulerTests {
    /// 10 pt per minute from 20:00, so half hours fall on multiples of 300 pt.
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var timeline: EPGTimeline {
        EPGTimeline(start: start, end: start.addingTimeInterval(6 * 3600), pointsPerMinute: 10)
    }

    private func at(minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60)
    }

    @Test func `parking lands on the half hour before the lead in`() {
        // Now at +47 min, 10 min lead in -> +37 -> floored to the +30 tick.
        #expect(timeline.halfHourParkingX(forNow: at(minutes: 47), leadIn: 10) == 300)
    }

    @Test func `a lead in crossing a half hour parks on the earlier tick`() {
        // Now at +35 min -> +25 -> the +0 tick.
        #expect(timeline.halfHourParkingX(forNow: at(minutes: 35), leadIn: 10) == 0)
    }

    @Test func `parking never goes before the window`() {
        #expect(timeline.halfHourParkingX(forNow: at(minutes: 3), leadIn: 10) == 0)
    }

    @Test func `parking always sits on a tick`() {
        for minute in stride(from: 40.0, through: 300, by: 7) {
            let parkedX = timeline.halfHourParkingX(forNow: at(minutes: minute), leadIn: 10)
            #expect(parkedX.truncatingRemainder(dividingBy: 300) == 0)
            // Now stays visible: at least the lead in, at most 40 min in.
            let leadIn = (minute * 10 - parkedX) / 10
            #expect(leadIn >= 10 && leadIn < 40)
        }
    }

    @Test func `ticks are limited to the requested range`() {
        let ticks = timeline.halfHourTicks(from: 250, to: 950)
        #expect(ticks == [at(minutes: 30), at(minutes: 60), at(minutes: 90)])
    }

    @Test func `the tick range clamps to the window`() {
        #expect(timeline.halfHourTicks(from: -500, to: 0) == [start])
        #expect(timeline.halfHourTicks(from: 3500, to: 99999) == [at(minutes: 360)])
        #expect(timeline.halfHourTicks(from: 950, to: 250).isEmpty)
    }

    @Test func `labels near now hide under the pill`() {
        let now = at(minutes: 47)
        #expect(EPGTimeline.tickIsCoveredByNowPill(at(minutes: 40), now: now))
        #expect(EPGTimeline.tickIsCoveredByNowPill(at(minutes: 50), now: now))
        #expect(!EPGTimeline.tickIsCoveredByNowPill(at(minutes: 30), now: now))
        #expect(!EPGTimeline.tickIsCoveredByNowPill(at(minutes: 60), now: now))
    }
}
