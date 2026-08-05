//
//  SyncFrequency.swift
//  Lume
//
//  How often playlists are automatically re-synced in the background.
//
//  The choice is global — it applies to every playlist — and is persisted via
//  `@AppStorage(SyncFrequency.storageKey)`. Whether a *specific* playlist takes
//  part is still gated by its own `syncEnabled` flag. The actual decision of
//  "is this playlist due for a sync right now" lives in `AutoSync.shouldSync`,
//  which the launch / playlist-switch / foreground triggers in `MainTabView`
//  call through.
//

import Foundation
import SwiftUI

// MARK: - SyncFrequency

enum SyncFrequency: String, CaseIterable, Identifiable {
    case sixHours
    case daily
    case everyThreeDays
    case weekly

    /// `@AppStorage` key holding the selected raw value.
    static let storageKey = "lume.syncFrequency"

    /// Default per issue #22: every 3 days.
    static let defaultValue: SyncFrequency = .everyThreeDays

    /// Resolves a stored raw value to a case, falling back to the default for an
    /// empty / unknown string.
    static func resolve(_ raw: String) -> SyncFrequency {
        SyncFrequency(rawValue: raw) ?? .defaultValue
    }

    var id: String {
        rawValue
    }

    /// Minimum age of a playlist's `lastSyncDate` before it is considered stale
    /// and eligible for an automatic re-sync.
    var interval: TimeInterval {
        switch self {
        case .sixHours: 6 * 60 * 60
        case .daily: 24 * 60 * 60
        case .everyThreeDays: 3 * 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .sixHours: "Every 6 Hours"
        case .daily: "Every Day"
        case .everyThreeDays: "Every 3 Days"
        case .weekly: "Every Week"
        }
    }

    /// Whether a playlist whose last successful sync was `lastSyncDate` is due
    /// for an automatic re-sync now. A playlist that has never synced is always
    /// due, so first launch triggers the initial sync.
    func isDue(lastSyncDate: Date?, now: Date = Date()) -> Bool {
        guard let lastSyncDate else { return true }
        return now.timeIntervalSince(lastSyncDate) >= interval
    }
}

// MARK: - EPG schedule

extension SyncFrequency {
    /// `@AppStorage` key for the EPG guide's own refresh interval — independent
    /// of the content sync frequency, since guide data changes far more often
    /// than the catalog.
    static let epgStorageKey = "lume.epgSyncFrequency"

    /// EPG defaults to a daily refresh.
    static let epgDefaultValue: SyncFrequency = .daily

    /// UserDefaults key holding the last successful full EPG sync as a unix
    /// timestamp. EPG sync is global (all sources at once), so the timestamp
    /// lives here rather than on any one source.
    static let epgLastSyncKey = "lume.epgLastSyncDate"

    /// Resolves a stored raw value to a case, falling back to the EPG default.
    static func resolveEPG(_ raw: String) -> SyncFrequency {
        SyncFrequency(rawValue: raw) ?? epgDefaultValue
    }
}

/// The global last-EPG-sync timestamp, persisted in UserDefaults. Read by the
/// auto-sync gate and stamped by `EPGSyncService` after a successful refresh.
enum EPGSyncSchedule {
    static var lastSyncDate: Date? {
        get {
            let stamp = UserDefaults.standard.double(forKey: SyncFrequency.epgLastSyncKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: SyncFrequency.epgLastSyncKey)
        }
    }
}

// MARK: - AutoSync

/// The full gate for "should this playlist auto-sync right now". Pure so it can
/// be unit-tested without SwiftUI / SwiftData state.
enum AutoSync {
    /// - Parameters:
    ///   - syncEnabled: the playlist's own opt-in flag.
    ///   - status: its current sync status (skip if already syncing).
    ///   - lastSyncDate: when it last finished a successful sync.
    ///   - frequency: the global frequency setting.
    ///   - alreadyStarted: whether this session has already kicked off a sync for
    ///     it that hasn't finished yet (avoids double-triggering from rapid view
    ///     updates before `status` flips to `.syncing`).
    static func shouldSync(
        syncEnabled: Bool,
        status: SyncStatus,
        lastSyncDate: Date?,
        frequency: SyncFrequency,
        alreadyStarted: Bool,
        now: Date = Date()
    ) -> Bool {
        syncEnabled
            && status != .syncing
            && !alreadyStarted
            && frequency.isDue(lastSyncDate: lastSyncDate, now: now)
    }

    /// Whether a background EPG refresh must stand aside for this playlist:
    /// its content sync is either running right now or due to start.
    ///
    /// Both downloads hit the same provider account, and Xtream panels
    /// commonly cap an account at one concurrent connection — a guide
    /// download racing the catalog sync gets one of the two rejected (and can
    /// leave the account briefly blocked, failing the sync's next requests
    /// too). Deferring costs nothing: the post-sync hook re-kicks the refresh
    /// as soon as the content sync queue drains.
    static func blocksEPGRefresh(
        syncEnabled: Bool,
        status: SyncStatus,
        lastSyncDate: Date?,
        frequency: SyncFrequency,
        now: Date = Date()
    ) -> Bool {
        status == .syncing || shouldSync(
            syncEnabled: syncEnabled,
            status: status,
            lastSyncDate: lastSyncDate,
            frequency: frequency,
            alreadyStarted: false,
            now: now
        )
    }
}
