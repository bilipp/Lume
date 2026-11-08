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
//  Being due is necessary but not sufficient: a due playlist that is not on
//  screen — not a member of the resolved `CatalogScope` — waits for the viewer
//  to switch to it. See `AutoSync.shouldSync` for why.
//

import Foundation
import SwiftData
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
        /// Whether the content tabs are showing it: a member of the resolved
        /// `CatalogScope` — the one playlist in isolated mode, any member in
        /// Combined.
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
    /// Only the playlists on screen earn that. Every content surface scopes to
    /// the resolved `CatalogScope`, so a stale playlist outside it changes
    /// nothing the viewer can see; it syncs when they switch to it, which is the
    /// moment its freshness starts to matter and which `MainTabView` already
    /// triggers on.
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

extension AutoSync {
    /// Whether a queued sync takes the screen with the blocking cover.
    ///
    /// In isolated mode the one playlist on screen is the whole library, so it
    /// always does. In Combined a member that already has rows keeps the rest of
    /// the library browsable and refreshes in the background; only one with
    /// nothing to show yet blocks, since its tabs would otherwise look broken.
    static func presentsCover(isCombined: Bool, hasContent: @autoclosure () -> Bool) -> Bool {
        !isCombined || !hasContent()
    }

    /// Whether any catalog row belongs to `playlistID`. One `LIMIT 1` seek on
    /// the unique `id` index per table, stopping at the first hit.
    static func hasContent(_ playlistID: UUID, in context: ModelContext) -> Bool {
        func exists<T: PersistentModel>(_ predicate: Predicate<T>) -> Bool {
            var descriptor = FetchDescriptor<T>(predicate: predicate)
            descriptor.fetchLimit = 1
            return !((try? context.fetchIdentifiers(descriptor)) ?? []).isEmpty
        }
        let scope = CatalogScope.isolated(playlistID)
        return exists(scope.liveStreamPredicate()) || exists(scope.moviePredicate()) || exists(scope.seriesPredicate())
    }

    /// The playlists a manual Sync in Combined queues, in priority order: the
    /// members that are due, or every member when none is — the viewer asked
    /// for a refresh, and one that does nothing reads as broken. Members
    /// already syncing are left out.
    static func manualMemberSyncs(
        _ members: [Playlist],
        frequency: SyncFrequency,
        now: Date = Date()
    ) -> [Playlist] {
        let idle = members.filter { $0.syncStatus != .syncing }
        let due = idle.filter { frequency.isDue(lastSyncDate: $0.lastSyncDate, now: now) }
        return due.isEmpty ? idle : due
    }
}

extension AutoSync {
    /// Runs one playlist sync. Reported to the guide refresh so the two never
    /// share the provider's connection allowance: it stands aside (or is cut
    /// short) while this runs, and catches up once nothing else is pending —
    /// see `EPGRefreshGate`. Every start is paired with exactly one finish.
    ///
    /// Newly synced titles need indexing; the launch-time pass may already be
    /// finished, so a fresh one is kicked — held off a few seconds so loading
    /// the embedding model and the per-chunk saves don't fight the first
    /// browse of the catalog just synced.
    static func runSync(
        _ playlist: Playlist,
        container: ModelContainer,
        progress: SyncProgress? = nil,
        full: Bool = false
    ) async throws {
        let epgSync = EPGSyncService.shared
        epgSync.contentSyncDidStart()
        var succeeded = false
        defer { epgSync.contentSyncDidFinish(succeeded: succeeded) }
        let syncManager = ContentSyncManager(modelContainer: container)
        try await BackgroundActivity.perform("Playlist sync") {
            try await syncManager.syncPlaylist(playlist, progress: progress, full: full)
        }
        succeeded = true
        ContentIndexingService.shared.kick(after: .seconds(3))
    }

    /// Runs the sync the blocking cover drives, without the cover. A failure
    /// is recorded on the playlist's own status; the next due pass retries it.
    static func syncInBackground(_ playlist: Playlist, container: ModelContainer) async {
        try? await runSync(playlist, container: container)
    }
}

extension [Playlist] {
    /// These playlists with the scope's members first, in priority order, then
    /// the rest as given.
    func inPriorityOrder(of scope: CatalogScope) -> [Playlist] {
        members(of: scope) + filter { !scope.playlistIDs.contains($0.id) }
    }
}

extension Playlist {
    /// This playlist as `AutoSync.shouldSync` sees it, given the scope the
    /// content tabs are showing (`[Playlist].scope(for:isPremium:)`).
    func autoSyncCandidate(in scope: CatalogScope) -> AutoSync.Candidate {
        AutoSync.Candidate(
            syncEnabled: syncEnabled,
            status: syncStatus,
            lastSyncDate: lastSyncDate,
            isActive: scope.playlistIDs.contains(id),
            wasAddedThisSession: AutoSync.addedThisSession.contains(id)
        )
    }
}
