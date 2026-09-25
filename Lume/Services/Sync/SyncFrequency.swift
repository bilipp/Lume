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
//  Being due is necessary but not sufficient: a due playlist that is not the
//  one on screen waits for the viewer to switch to it. See `AutoSync.shouldSync`
//  for why.
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

    /// UserDefaults key holding the guide-schema version the store was last
    /// refreshed under. Bumped whenever a release starts capturing new XMLTV
    /// signals (sub-titles, categories) so existing users' next launch treats
    /// the guide refresh as due once and back-fills the new columns.
    static let epgSchemaKey = "epg.schemaVersion"

    /// The guide-schema version this build ingests. A stored value below this
    /// forces one EPG refresh; see `EPGSyncService.isDue`.
    static let epgCurrentSchemaVersion = 2

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

    /// The guide-schema version the store was last refreshed under. Absent (0)
    /// for stores predating the stamp, which is below the current version and so
    /// forces one refresh.
    static var schemaVersion: Int {
        get { UserDefaults.standard.integer(forKey: SyncFrequency.epgSchemaKey) }
        set { UserDefaults.standard.set(newValue, forKey: SyncFrequency.epgSchemaKey) }
    }
}

// MARK: - AutoSync

/// The full gate for "should this playlist auto-sync right now". Pure so it can
/// be unit-tested without SwiftUI / SwiftData state.
enum AutoSync {
    /// A playlist as the auto-sync gate sees it. Grouped because these fields
    /// always travel together, and taken loose rather than as a `Playlist` so
    /// the gate stays testable without a `ModelContext` — the same reason
    /// `PlaylistSyncState.resolve` next door takes its fields loose.
    struct Candidate {
        /// The playlist's own opt-in flag.
        let syncEnabled: Bool
        /// Its current sync status (skip if already syncing).
        let status: SyncStatus
        /// When it last finished a successful sync.
        let lastSyncDate: Date?
        /// Whether this is the playlist the content tabs are showing.
        let isActive: Bool
        /// Whether the viewer added it on this device since launch — see
        /// `addedThisSession`.
        let wasAddedThisSession: Bool
    }

    /// Playlists the viewer added on this device since launch, recorded by the
    /// add flow. Session-scoped on purpose: it separates "just added, expected
    /// to fill in" from the other ways a playlist ends up never-synced — one
    /// that arrived from iCloud on a new device, or whose first import was
    /// interrupted — which wait for the viewer like any other stale playlist.
    static var addedThisSession: Set<UUID> = []

    /// Auto-sync hands the screen to a blocking progress cover, so with several
    /// playlists configured, launching used to mean sitting through one cover
    /// per playlist — on a large catalog, minutes each.
    ///
    /// Only the active playlist earns that. Every content surface scopes to
    /// `playlists.active(for:)`, so a stale *other* playlist changes nothing the
    /// viewer can see; it syncs when they switch to it, which is the moment its
    /// freshness starts to matter and which `MainTabView` already triggers on.
    ///
    /// The exception is a playlist just added from Settings, which syncs
    /// wherever it is: the add doesn't select it, and the viewer adding one
    /// expects it to be ready when they go looking for it. The exception is
    /// keyed on the add rather than on `lastSyncDate == nil`, which would also
    /// catch every playlist iCloud brings to a new device and put one cover per
    /// playlist right back.
    ///
    /// - Parameter alreadyStarted: whether this session has already kicked off a
    ///   sync for it that hasn't finished yet (avoids double-triggering from
    ///   rapid view updates before `status` flips to `.syncing`).
    static func shouldSync(
        _ candidate: Candidate,
        frequency: SyncFrequency,
        alreadyStarted: Bool,
        now: Date = Date()
    ) -> Bool {
        candidate.syncEnabled
            && candidate.status != .syncing
            && !alreadyStarted
            && (candidate.isActive || candidate.wasAddedThisSession)
            && frequency.isDue(lastSyncDate: candidate.lastSyncDate, now: now)
    }
}

extension Playlist {
    /// This playlist as `AutoSync.shouldSync` sees it, given the id of the
    /// playlist on screen (`[Playlist].activeID(for:)`).
    func autoSyncCandidate(activeID: String) -> AutoSync.Candidate {
        AutoSync.Candidate(
            syncEnabled: syncEnabled,
            status: syncStatus,
            lastSyncDate: lastSyncDate,
            isActive: id.uuidString == activeID,
            wasAddedThisSession: AutoSync.addedThisSession.contains(id)
        )
    }
}
