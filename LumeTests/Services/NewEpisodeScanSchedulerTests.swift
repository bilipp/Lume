import Foundation
@testable import Lume
import Testing

struct NewEpisodeScanSchedulerTests {
    private let key = NewEpisodeScanScheduler.storageKey
    private let interval = NewEpisodeScanScheduler.scanInterval

    private func clearStoredDate() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test func `is due when no date stored`() {
        clearStoredDate()
        #expect(NewEpisodeScanScheduler.isDue())
    }

    @Test func `is due after full interval has elapsed`() {
        clearStoredDate()
        let past = Date(timeIntervalSinceNow: -(interval + 1))
        UserDefaults.standard.set(past, forKey: key)
        #expect(NewEpisodeScanScheduler.isDue())
    }

    @Test func `is not due before interval elapses`() {
        clearStoredDate()
        let recent = Date(timeIntervalSinceNow: -(interval - 60))
        UserDefaults.standard.set(recent, forKey: key)
        #expect(!NewEpisodeScanScheduler.isDue())
    }

    @Test func `is not due immediately after markComplete`() {
        clearStoredDate()
        NewEpisodeScanScheduler.markComplete()
        #expect(!NewEpisodeScanScheduler.isDue())
    }

    @Test func `markComplete persists a date`() {
        clearStoredDate()
        NewEpisodeScanScheduler.markComplete()
        let stored = UserDefaults.standard.object(forKey: key) as? Date
        #expect(stored != nil)
    }

    @Test func `is due exactly at the boundary`() {
        clearStoredDate()
        let boundary = Date(timeIntervalSinceNow: -interval)
        UserDefaults.standard.set(boundary, forKey: key)
        #expect(NewEpisodeScanScheduler.isDue())
    }
}
