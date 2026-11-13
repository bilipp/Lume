import Foundation
@testable import Lume
import Testing

struct TimeshiftPreferencesTests {
    @Test func `duration options and storage estimate`() {
        #expect(TimeshiftPreferences.normalizedMinutes(0) == 1)
        #expect(TimeshiftPreferences.normalizedMinutes(17) == 15)
        #expect(TimeshiftPreferences.normalizedMinutes(18) == 20)
        #expect(TimeshiftPreferences.normalizedMinutes(999) == 60)
        #expect(TimeshiftPreferences.estimatedBytes(minutes: 15, bitsPerSecond: 8_000_000) == 900_000_000)
        #expect(TimeshiftPreferences.estimatedBytes(minutes: 30, bitsPerSecond: 8_000_000) == 1_800_000_000)
        #expect(TimeshiftPreferences.estimatedBytes(minutes: 15, bitsPerSecond: .nan) == 900_000_000)
    }

    @Test func `short buffers and previously saved large buffers`() {
        #expect(TimeshiftPreferences.minuteOptions == [1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60])
        for value in 1 ... 4 {
            #expect(TimeshiftPreferences.normalizedMinutes(value) == value)
        }
        #expect(TimeshiftPreferences.normalizedMinutes(180) == 60)
        #expect(TimeshiftPreferences.estimatedBytes(minutes: 1, bitsPerSecond: 8_000_000) == 60_000_000)
        #expect(TimeshiftPreferences.estimatedBytes(minutes: 60, bitsPerSecond: 8_000_000) == 3_600_000_000)
    }

    @Test func `provider duration does not extend programme timeline`() {
        #expect(TimeshiftPreferences.displayDuration(engine: 13 * 3600, programme: 1800, limitToProgramme: true) == 1800)
        #expect(TimeshiftPreferences.displayDuration(engine: 13 * 3600, programme: 1800, limitToProgramme: false) == 13 * 3600)
        #expect(TimeshiftPreferences.displayDuration(engine: .infinity, programme: 1800, limitToProgramme: true) == 1800)
        #expect(TimeshiftPreferences.displayDuration(engine: 600, programme: nil, limitToProgramme: true) == 600)
    }

    @Test func `seeking inside one minute segments preserves seconds`() throws {
        var window = try TimeshiftWindow()
        _ = try window.append(id: 1, duration: 60, bytes: 1)
        _ = try window.append(id: 2, duration: 60, bytes: 1)
        let target = try #require(TimeshiftSeekTarget(position: 75, entries: window.entries))
        #expect(target.sequence == 2)
        #expect(target.origin == 60)
        #expect(target.offset == 15)
        let slider = try #require(TimeshiftSeekTarget(position: 87.5, entries: window.entries))
        #expect(slider.offset == 27.5)
    }
}
