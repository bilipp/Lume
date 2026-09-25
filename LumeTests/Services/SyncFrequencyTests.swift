import Foundation
@testable import Lume
import Testing

struct SyncFrequencyTests {
    // MARK: - defaults

    @Test func `default is every three days`() {
        #expect(SyncFrequency.defaultValue == .everyThreeDays)
    }

    @Test func `never synced is always due`() {
        for frequency in SyncFrequency.allCases {
            #expect(frequency.isDue(lastSyncDate: nil))
        }
    }

    // MARK: - interval

    @Test func `six hours interval`() {
        #expect(SyncFrequency.sixHours.interval == 6 * 60 * 60)
    }

    @Test func `daily interval`() {
        #expect(SyncFrequency.daily.interval == 24 * 60 * 60)
    }

    @Test func `every three days interval`() {
        #expect(SyncFrequency.everyThreeDays.interval == 3 * 24 * 60 * 60)
    }

    @Test func `weekly interval`() {
        #expect(SyncFrequency.weekly.interval == 7 * 24 * 60 * 60)
    }

    // MARK: - isDue

    @Test func `isDue returns true when no last sync date`() {
        #expect(SyncFrequency.daily.isDue(lastSyncDate: nil))
    }

    @Test func `isDue returns true when enough time has passed`() {
        let past = Date().addingTimeInterval(-25 * 60 * 60)
        #expect(SyncFrequency.daily.isDue(lastSyncDate: past))
    }

    @Test func `isDue returns false when not enough time has passed`() {
        let recent = Date().addingTimeInterval(-12 * 60 * 60)
        #expect(!SyncFrequency.daily.isDue(lastSyncDate: recent))
    }

    @Test func `isDue returns false for exact interval boundary below`() {
        let almost = Date().addingTimeInterval(-(24 * 60 * 60 - 1))
        #expect(!SyncFrequency.daily.isDue(lastSyncDate: almost))
    }

    @Test func `isDue returns true for exact interval boundary at or above`() {
        let boundary = Date().addingTimeInterval(-24 * 60 * 60)
        #expect(SyncFrequency.daily.isDue(lastSyncDate: boundary))
    }

    @Test func `isDue weekly returns true after a week`() {
        let past = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        #expect(SyncFrequency.weekly.isDue(lastSyncDate: past))
    }

    @Test func `isDue weekly returns false within a week`() {
        let recent = Date().addingTimeInterval(-6 * 24 * 60 * 60)
        #expect(!SyncFrequency.weekly.isDue(lastSyncDate: recent))
    }

    // MARK: - resolve

    @Test func `resolve returns matching frequency`() {
        #expect(SyncFrequency.resolve("daily") == .daily)
    }

    @Test func `resolve falls back to default for unknown value`() {
        #expect(SyncFrequency.resolve("bogus") == SyncFrequency.defaultValue)
    }

    @Test func `resolve falls back to default for empty string`() {
        #expect(SyncFrequency.resolve("") == SyncFrequency.defaultValue)
    }

    // MARK: - resolveEPG

    @Test func `resolveEPG returns matching frequency`() {
        #expect(SyncFrequency.resolveEPG("weekly") == .weekly)
    }

    @Test func `resolveEPG falls back to epg default for unknown value`() {
        #expect(SyncFrequency.resolveEPG("bogus") == SyncFrequency.epgDefaultValue)
        #expect(SyncFrequency.epgDefaultValue == .daily)
    }

    // MARK: - AutoSync

    @Test func `auto sync returns true when all conditions met`() {
        #expect(AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: Date().addingTimeInterval(-48 * 60 * 60),
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync returns false when sync disabled`() {
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: false,
                status: .idle,
                lastSyncDate: Date().addingTimeInterval(-48 * 60 * 60),
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync returns false when already syncing`() {
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .syncing,
                lastSyncDate: Date().addingTimeInterval(-48 * 60 * 60),
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync returns false when already started`() {
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: Date().addingTimeInterval(-48 * 60 * 60),
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: true
        ))
    }

    @Test func `auto sync returns false when not due`() {
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: Date().addingTimeInterval(-12 * 60 * 60),
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync triggers after error when due`() {
        #expect(AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .error,
                lastSyncDate: nil,
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync returns true when never synced`() {
        #expect(AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: nil,
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync uses custom now date`() {
        let now = Date()
        #expect(AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: now.addingTimeInterval(-48 * 60 * 60),
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false,
            now: now
        ))
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: now.addingTimeInterval(-12 * 60 * 60),
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false,
            now: now
        ))
    }

    // MARK: - AutoSync scoping

    @Test func `auto sync defers a due playlist that is not on screen`() {
        // The whole point: with several playlists configured, launching should
        // not queue a blocking cover for each of them in turn.
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: Date().addingTimeInterval(-48 * 60 * 60),
                isActive: false,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync runs a playlist just added that is not on screen`() {
        // Adding a playlist from Settings doesn't select it, and the viewer
        // expects it ready when they go looking for it.
        #expect(AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: nil,
                isActive: false,
                wasAddedThisSession: true
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync defers a never-synced playlist it did not just add`() {
        // iCloud brings every playlist to a new device never-synced; syncing
        // each wherever it stands would put one cover per playlist back.
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: nil,
                isActive: false,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync runs a deferred playlist once it becomes active`() {
        // The playlist-switch trigger is what picks up whatever launch skipped,
        // so the same playlist must flip to eligible on nothing but `isActive`.
        let stale = Date().addingTimeInterval(-48 * 60 * 60)
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: stale,
                isActive: false,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
        #expect(AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .idle,
                lastSyncDate: stale,
                isActive: true,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    @Test func `auto sync defers a failed playlist that is not on screen`() {
        // An error still leaves a cached catalog behind, so a retry can wait for
        // the viewer to go there — unlike the never-synced case above.
        #expect(!AutoSync.shouldSync(
            AutoSync.Candidate(
                syncEnabled: true,
                status: .error,
                lastSyncDate: Date().addingTimeInterval(-48 * 60 * 60),
                isActive: false,
                wasAddedThisSession: false
            ),
            frequency: .daily,
            alreadyStarted: false
        ))
    }

    // MARK: - EPGRefreshGate

    @Test func `epg refresh runs when no content sync is pending`() {
        var gate = EPGRefreshGate()
        let allowed1 = gate.request()
        #expect(allowed1)
        #expect(!gate.isRefreshOwed)
    }

    @Test func `epg refresh waits for the auto-sync queue and runs once it drains`() {
        var gate = EPGRefreshGate()
        gate.isAutoSyncQueued = true
        let allowed1 = gate.request()
        #expect(!allowed1)
        let owedRuns2 = gate.takeOwedRefresh()
        #expect(!owedRuns2)

        gate.isAutoSyncQueued = false
        let owedRuns3 = gate.takeOwedRefresh()
        #expect(owedRuns3)
        let owedRuns4 = gate.takeOwedRefresh()
        #expect(!owedRuns4)
    }

    @Test func `epg refresh waits for a running sync outside the queue`() {
        // A manual "Sync Now" from Settings, on any playlist.
        var gate = EPGRefreshGate()
        gate.contentSyncStarted()
        let allowed1 = gate.request()
        #expect(!allowed1)

        gate.contentSyncFinished(succeeded: false)
        let owedRuns2 = gate.takeOwedRefresh()
        #expect(owedRuns2)
    }

    @Test func `a successful sync owes a refresh even when nothing asked for one`() {
        // A freshly synced playlist's channels shouldn't wait for the schedule.
        var gate = EPGRefreshGate()
        gate.isAutoSyncQueued = true
        gate.contentSyncStarted()
        gate.contentSyncFinished(succeeded: true)
        let owedRuns1 = gate.takeOwedRefresh()
        #expect(!owedRuns1)

        gate.isAutoSyncQueued = false
        let owedRuns2 = gate.takeOwedRefresh()
        #expect(owedRuns2)
    }

    @Test func `an aborted or failed sync owes nothing of its own`() {
        var gate = EPGRefreshGate()
        gate.contentSyncStarted()
        gate.contentSyncFinished(succeeded: false)
        let owedRuns1 = gate.takeOwedRefresh()
        #expect(!owedRuns1)
    }

    @Test func `a stale playlist nobody is syncing never holds the guide back`() {
        // The tvOS quick switch lands on a stale playlist without syncing it:
        // nothing is queued or running, so the guide is free to go.
        var gate = EPGRefreshGate()
        gate.isAutoSyncQueued = false
        let allowed1 = gate.request()
        #expect(allowed1)
    }

    @Test func `a refresh cut short for a content sync runs after it`() {
        var gate = EPGRefreshGate()
        let allowed1 = gate.request()
        #expect(allowed1)
        gate.contentSyncStarted()
        gate.owe()
        let owedRuns2 = gate.takeOwedRefresh()
        #expect(!owedRuns2)

        gate.contentSyncFinished(succeeded: false)
        let owedRuns3 = gate.takeOwedRefresh()
        #expect(owedRuns3)
    }

    @Test func `overlapping syncs hold the guide until the last one finishes`() {
        var gate = EPGRefreshGate()
        gate.contentSyncStarted()
        gate.contentSyncStarted()
        gate.contentSyncFinished(succeeded: true)
        let owedRuns1 = gate.takeOwedRefresh()
        #expect(!owedRuns1)

        gate.contentSyncFinished(succeeded: true)
        let owedRuns2 = gate.takeOwedRefresh()
        #expect(owedRuns2)
    }

    // MARK: - label

    @Test func `sync frequency has labels`() {
        for frequency in SyncFrequency.allCases {
            #expect(!frequency.label.key.isEmpty)
        }
    }
}

/// Serialized: both tests mutate the same `UserDefaults.standard` key, so
/// running them in parallel races the shared value.
@Suite(.serialized)
struct EPGSyncScheduleTests {
    @Test func `epg sync schedule stores and retrieves date`() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        EPGSyncSchedule.lastSyncDate = date
        #expect(EPGSyncSchedule.lastSyncDate == date)
    }

    @Test func `epg sync schedule nil when never set`() {
        EPGSyncSchedule.lastSyncDate = nil
        #expect(EPGSyncSchedule.lastSyncDate == nil)
    }
}
