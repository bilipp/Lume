import Foundation
import OSLog
import SwiftData

/// Outcome of one reconcile pass — surfaced to the coordinator for status and
/// logging. Purely informational.
nonisolated struct CloudSyncReconcileResult: Equatable {
    var playlistsPushed = 0
    var playlistsPulled = 0
    var playlistsCreatedLocally = 0
    var contentPushed = 0
    var contentPulled = 0
    /// Cloud states whose local catalog item hasn't synced yet — left pending
    /// (shadow untouched) so a later pass applies them once the catalog lands.
    var contentPending = 0
}

/// A local catalog item paired with its current syncable state, gathered up-front
/// so a reconcile pass touches the store once per type. `nonisolated` so the
/// engine actor can hold and read it off the main actor (the project defaults to
/// main-actor isolation, which would otherwise isolate this struct's members).
private nonisolated struct LocalContentEntry {
    let values: ContentStateValues
    let kind: SyncedContentKind
    let model: any PersistentModel
}

/// Reconciles local SwiftData (the catalog + playlists) with the CloudKit-synced
/// mirror models (`SyncedPlaylist`, `UserContentState`) using the three-way
/// merge in `CloudSyncMerge`.
///
/// An `actor` that owns its own background `ModelContext` — the same pattern as
/// `ContentSyncManager` / `WatchProgressWriter` — so all store work stays off the
/// main thread. Saves on this context auto-merge into the main context, so
/// `@Query`-driven UI updates after a pull, and a newly pulled playlist trips
/// `MainTabView`'s auto-sync to fetch its catalog.
actor CloudSyncEngine {
    let context: ModelContext
    let shadow: CloudSyncShadow

    init(container: ModelContainer, shadow: CloudSyncShadow = CloudSyncShadow()) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.shadow = shadow
    }

    /// Run a full bidirectional reconcile: playlists first (so content can scope
    /// to the resulting live playlists), then per-content user state. Persists
    /// the shadow baseline and saves the context once at the end.
    @discardableResult
    func reconcile() -> CloudSyncReconcileResult {
        var result = CloudSyncReconcileResult()
        do {
            let livePrefixes = try reconcilePlaylists(into: &result)
            try reconcileContent(livePrefixes: livePrefixes, into: &result)
            if context.hasChanges {
                try context.save()
            }
            shadow.persist()
            Logger.sync.info("Reconcile pl +\(result.playlistsPushed) new \(result.playlistsCreatedLocally) ct +\(result.contentPushed)/\(result.contentPulled) pend \(result.contentPending)")
        } catch {
            Logger.sync.error("Reconcile failed: \(error.localizedDescription)")
        }
        return result
    }

    // MARK: - Playlists

    /// Returns the set of "live" playlist UUID strings (present locally or in the
    /// cloud after this pass) so the content pass can garbage-collect state whose
    /// playlist is gone.
    private func reconcilePlaylists(into result: inout CloudSyncReconcileResult) throws -> Set<String> {
        let localByID = try fetchLocalPlaylists()
        let mirrorsByID = try fetchPlaylistMirrors()

        var ids = Set(localByID.keys).union(mirrorsByID.keys)
        ids.formUnion(shadow.playlistShadowIDs().compactMap(UUID.init(uuidString:)))

        var live = Set<String>()
        for id in ids {
            let key = id.uuidString
            let verdict = CloudSyncMerge.reconcile(
                local: localByID[id].map(Self.values(from:)),
                cloud: mirrorsByID[id].map(Self.values(from:)),
                shadow: shadow.playlistShadow(key),
                mergeConflict: PlaylistConfigValues.mergeConflict
            )
            applyPlaylistVerdict(verdict, id: id, local: localByID[id], mirror: mirrorsByID[id], into: &result)

            if Self.playlistRemains(verdict: verdict, hadLocal: localByID[id] != nil, hadCloud: mirrorsByID[id] != nil) {
                live.insert(key)
            }
        }
        return live
    }

    // MARK: - Content state

    private func reconcileContent(livePrefixes: Set<String>, into result: inout CloudSyncReconcileResult) throws {
        let mirrors = try fetchContentMirrors()
        let localValues = try fetchLocalContentValues()

        var ids = Set(mirrors.keys).union(localValues.keys)
        ids.formUnion(shadow.contentShadowIDs())

        for id in ids {
            // Garbage-collect state whose owning playlist no longer exists on
            // either side (deleted however). Clear the cloud record, reset any
            // local orphan, and drop the shadow.
            guard livePrefixes.contains(String(id.prefix(36))) else {
                if let mirror = mirrors[id] { context.delete(mirror) }
                if let entry = localValues[id] { resetLocalContent(entry) }
                shadow.setContentShadow(id, nil)
                continue
            }

            let verdict = CloudSyncMerge.reconcile(
                local: localValues[id]?.values,
                cloud: mirrors[id].map(Self.values(from:)),
                shadow: shadow.contentShadow(id),
                mergeConflict: ContentStateValues.mergeConflict
            )
            try applyContentVerdict(
                verdict,
                id: id,
                mirror: mirrors[id],
                loaded: localValues[id]?.model,
                into: &result
            )
        }
    }
}

// MARK: - Verdict application

private extension CloudSyncEngine {
    func applyPlaylistVerdict(
        _ verdict: MergeVerdict<PlaylistConfigValues>,
        id: UUID,
        local: Playlist?,
        mirror: SyncedPlaylist?,
        into result: inout CloudSyncReconcileResult
    ) {
        let key = id.uuidString
        switch verdict {
        case .noChange:
            break
        case let .pushToCloud(value):
            applyPlaylistToCloud(value, id: id, mirror: mirror)
            if value != nil { result.playlistsPushed += 1 }
            shadow.setPlaylistShadow(key, value)
        case let .pullToLocal(value):
            if applyPlaylistToLocal(value, id: id, local: local) { result.playlistsCreatedLocally += 1 }
            if value != nil { result.playlistsPulled += 1 }
            shadow.setPlaylistShadow(key, value)
        case let .writeBoth(value):
            applyPlaylistToCloud(value, id: id, mirror: mirror)
            if applyPlaylistToLocal(value, id: id, local: local) { result.playlistsCreatedLocally += 1 }
            result.playlistsPushed += 1
            shadow.setPlaylistShadow(key, value)
        }
    }

    func applyContentVerdict(
        _ verdict: MergeVerdict<ContentStateValues>,
        id: String,
        mirror: UserContentState?,
        loaded: (any PersistentModel)?,
        into result: inout CloudSyncReconcileResult
    ) throws {
        let kind = mirror?.kind ?? Self.kind(of: loaded)
        switch verdict {
        case .noChange:
            break
        case let .pushToCloud(value):
            applyContentToCloud(value, id: id, kind: kind, mirror: mirror)
            if value != nil { result.contentPushed += 1 }
            shadow.setContentShadow(id, value)
        case let .pullToLocal(value):
            // A missing catalog item leaves the change pending (shadow untouched).
            guard try applyContentToLocal(value, id: id, kind: kind, loaded: loaded) else {
                result.contentPending += 1
                return
            }
            if value != nil { result.contentPulled += 1 }
            shadow.setContentShadow(id, value)
        case let .writeBoth(value):
            guard try applyContentToLocal(value, id: id, kind: kind, loaded: loaded) else {
                result.contentPending += 1
                return
            }
            applyContentToCloud(value, id: id, kind: kind, mirror: mirror)
            result.contentPushed += 1
            shadow.setContentShadow(id, value)
        }
    }
}

// MARK: - Playlist mutations

private extension CloudSyncEngine {
    func applyPlaylistToCloud(_ value: PlaylistConfigValues?, id: UUID, mirror: SyncedPlaylist?) {
        guard let value else {
            if let mirror { context.delete(mirror) }
            return
        }
        if let mirror {
            mirror.name = value.name
            mirror.serverURL = value.serverURL
            mirror.username = value.username
            mirror.password = value.password
            mirror.sourceTypeRaw = value.sourceTypeRaw
            mirror.epgURL = value.epgURL
            mirror.syncEnabled = value.syncEnabled
            mirror.updatedAt = Date()
        } else {
            context.insert(SyncedPlaylist(
                id: id,
                name: value.name,
                serverURL: value.serverURL,
                username: value.username,
                password: value.password,
                sourceTypeRaw: value.sourceTypeRaw,
                epgURL: value.epgURL,
                syncEnabled: value.syncEnabled
            ))
        }
    }

    /// Returns true if a new local `Playlist` was created (it has no
    /// `lastSyncDate`, so the UI's auto-sync will fetch its catalog).
    func applyPlaylistToLocal(_ value: PlaylistConfigValues?, id: UUID, local: Playlist?) -> Bool {
        guard let value else {
            if let local { context.delete(local) }
            return false
        }
        if let local {
            local.name = value.name
            local.serverURL = value.serverURL
            local.username = value.username
            local.password = value.password
            local.sourceTypeRaw = value.sourceTypeRaw
            local.epgURL = value.epgURL
            local.syncEnabled = value.syncEnabled
            return false
        }
        let playlist = Playlist(name: value.name, serverURL: value.serverURL, username: value.username, password: value.password)
        playlist.id = id
        playlist.sourceTypeRaw = value.sourceTypeRaw
        playlist.epgURL = value.epgURL
        playlist.syncEnabled = value.syncEnabled
        context.insert(playlist)
        return true
    }

    static func playlistRemains(verdict: MergeVerdict<PlaylistConfigValues>, hadLocal: Bool, hadCloud: Bool) -> Bool {
        switch verdict {
        case .noChange: hadLocal || hadCloud
        case let .pushToCloud(value), let .pullToLocal(value): value != nil
        case .writeBoth: true
        }
    }
}

// MARK: - Content mutations

private extension CloudSyncEngine {
    static func kind(of model: (any PersistentModel)?) -> SyncedContentKind? {
        switch model {
        case is Movie: .movie
        case is Series: .series
        case is Episode: .episode
        case is LiveStream: .live
        default: nil
        }
    }

    func applyContentToCloud(_ value: ContentStateValues?, id: String, kind: SyncedContentKind?, mirror: UserContentState?) {
        guard let value, !value.isEmpty else {
            if let mirror { context.delete(mirror) }
            return
        }
        let kind = kind ?? mirror?.kind ?? .movie
        if let mirror {
            mirror.kindRaw = kind.rawValue
            mirror.watchProgress = value.watchProgress
            mirror.isWatched = value.isWatched
            mirror.lastWatchedDate = value.lastWatchedDate
            mirror.isFavorite = value.isFavorite
            mirror.addedToWatchlistDate = value.addedToWatchlistDate
            mirror.favoriteOrder = value.favoriteOrder
            mirror.updatedAt = Date()
        } else {
            context.insert(UserContentState(
                contentId: id,
                kind: kind,
                watchProgress: value.watchProgress,
                isWatched: value.isWatched,
                lastWatchedDate: value.lastWatchedDate,
                isFavorite: value.isFavorite,
                addedToWatchlistDate: value.addedToWatchlistDate,
                favoriteOrder: value.favoriteOrder
            ))
        }
    }

    /// Applies a cloud value to the matching local catalog item. Returns false
    /// (without touching the shadow) when the catalog item hasn't synced to this
    /// device yet, so the change stays pending for a later pass.
    func applyContentToLocal(_ value: ContentStateValues?, id: String, kind: SyncedContentKind?, loaded: (any PersistentModel)?) throws -> Bool {
        guard let kind else { return true } // nothing to apply (shadow-only id)
        let values = value ?? ContentStateValues(watchProgress: 0, isWatched: false, lastWatchedDate: nil, isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil)

        switch kind {
        case .movie:
            guard let movie = try (loaded as? Movie) ?? fetchMovie(id) else { return false }
            movie.watchProgress = values.watchProgress
            movie.isWatched = values.isWatched
            movie.lastWatchedDate = values.lastWatchedDate
            movie.isFavorite = values.isFavorite
            movie.addedToWatchlistDate = values.addedToWatchlistDate
        case .series:
            guard let series = try (loaded as? Series) ?? fetchSeries(id) else { return false }
            series.isFavorite = values.isFavorite
            series.addedToWatchlistDate = values.addedToWatchlistDate
            series.lastWatchedDate = values.lastWatchedDate
        case .episode:
            guard let episode = try (loaded as? Episode) ?? fetchEpisode(id) else { return false }
            episode.watchProgress = values.watchProgress
            episode.isWatched = values.isWatched
            episode.lastWatchedDate = values.lastWatchedDate
        case .live:
            guard let stream = try (loaded as? LiveStream) ?? fetchLiveStream(id) else { return false }
            stream.isFavorite = values.isFavorite
            stream.favoriteOrder = values.favoriteOrder
        }
        return true
    }

    /// Resets an orphaned local item's user state to defaults so it stops
    /// regenerating cloud records after its playlist was deleted.
    func resetLocalContent(_ entry: LocalContentEntry) {
        switch entry.model {
        case let movie as Movie:
            movie.watchProgress = 0
            movie.isWatched = false
            movie.lastWatchedDate = nil
            movie.isFavorite = false
            movie.addedToWatchlistDate = nil
        case let series as Series:
            series.isFavorite = false
            series.addedToWatchlistDate = nil
            series.lastWatchedDate = nil
        case let episode as Episode:
            episode.watchProgress = 0
            episode.isWatched = false
            episode.lastWatchedDate = nil
        case let stream as LiveStream:
            stream.isFavorite = false
            stream.favoriteOrder = nil
        default:
            break
        }
    }
}

// MARK: - Fetch maps

private extension CloudSyncEngine {
    func fetchLocalPlaylists() throws -> [UUID: Playlist] {
        var map: [UUID: Playlist] = [:]
        for playlist in try context.fetch(FetchDescriptor<Playlist>()) {
            map[playlist.id] = playlist
        }
        return map
    }

    func fetchPlaylistMirrors() throws -> [UUID: SyncedPlaylist] {
        var map: [UUID: SyncedPlaylist] = [:]
        for mirror in try context.fetch(FetchDescriptor<SyncedPlaylist>()) {
            map[mirror.id] = dedupe(mirror, against: map[mirror.id])
        }
        return map
    }

    func fetchContentMirrors() throws -> [String: UserContentState] {
        var map: [String: UserContentState] = [:]
        for mirror in try context.fetch(FetchDescriptor<UserContentState>()) {
            map[mirror.contentId] = dedupe(mirror, against: map[mirror.contentId])
        }
        return map
    }

    /// Defensive de-duplication: CloudKit can momentarily surface two records for
    /// one key — keep the most recently updated and delete the loser.
    func dedupe<T: PersistentModel>(_ candidate: T, against existing: T?, updatedAt: (T) -> Date) -> T {
        guard let existing else { return candidate }
        if updatedAt(candidate) > updatedAt(existing) {
            context.delete(existing)
            return candidate
        }
        context.delete(candidate)
        return existing
    }

    func dedupe(_ candidate: SyncedPlaylist, against existing: SyncedPlaylist?) -> SyncedPlaylist {
        dedupe(candidate, against: existing, updatedAt: \.updatedAt)
    }

    func dedupe(_ candidate: UserContentState, against existing: UserContentState?) -> UserContentState {
        dedupe(candidate, against: existing, updatedAt: \.updatedAt)
    }

    func fetchLocalContentValues() throws -> [String: LocalContentEntry] {
        var map: [String: LocalContentEntry] = [:]
        try movieEntries().forEach { map[$0] = $1 }
        try seriesEntries().forEach { map[$0] = $1 }
        try episodeEntries().forEach { map[$0] = $1 }
        try liveEntries().forEach { map[$0] = $1 }
        return map
    }

    func movieEntries() throws -> [(String, LocalContentEntry)] {
        let movies = try context.fetch(FetchDescriptor<Movie>(
            predicate: #Predicate { $0.isFavorite || $0.watchProgress > 0 || $0.isWatched || $0.addedToWatchlistDate != nil }
        ))
        return movies.map { movie in
            (movie.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: movie.watchProgress,
                    isWatched: movie.isWatched,
                    lastWatchedDate: movie.lastWatchedDate,
                    isFavorite: movie.isFavorite,
                    addedToWatchlistDate: movie.addedToWatchlistDate,
                    favoriteOrder: nil
                ),
                kind: .movie,
                model: movie
            ))
        }
    }

    func seriesEntries() throws -> [(String, LocalContentEntry)] {
        let series = try context.fetch(FetchDescriptor<Series>(
            predicate: #Predicate { $0.isFavorite || $0.addedToWatchlistDate != nil || $0.lastWatchedDate != nil }
        ))
        return series.map { item in
            (item.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: 0,
                    isWatched: false,
                    lastWatchedDate: item.lastWatchedDate,
                    isFavorite: item.isFavorite,
                    addedToWatchlistDate: item.addedToWatchlistDate,
                    favoriteOrder: nil
                ),
                kind: .series,
                model: item
            ))
        }
    }

    func episodeEntries() throws -> [(String, LocalContentEntry)] {
        let episodes = try context.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.watchProgress > 0 || $0.isWatched }
        ))
        return episodes.map { episode in
            (episode.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: episode.watchProgress,
                    isWatched: episode.isWatched,
                    lastWatchedDate: episode.lastWatchedDate,
                    isFavorite: false,
                    addedToWatchlistDate: nil,
                    favoriteOrder: nil
                ),
                kind: .episode,
                model: episode
            ))
        }
    }

    /// Live streams sync only their favorite flag/order — channel-surfing
    /// "recently watched" stays device-local to avoid mirror bloat.
    func liveEntries() throws -> [(String, LocalContentEntry)] {
        let streams = try context.fetch(FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite }
        ))
        return streams.map { stream in
            (stream.id, LocalContentEntry(
                values: ContentStateValues(
                    watchProgress: 0,
                    isWatched: false,
                    lastWatchedDate: nil,
                    isFavorite: stream.isFavorite,
                    addedToWatchlistDate: nil,
                    favoriteOrder: stream.favoriteOrder
                ),
                kind: .live,
                model: stream
            ))
        }
    }

    func fetchMovie(_ id: String) throws -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchSeries(_ id: String) throws -> Series? {
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchEpisode(_ id: String) throws -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchLiveStream(_ id: String) throws -> LiveStream? {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

// MARK: - Value extraction

private extension CloudSyncEngine {
    static func values(from playlist: Playlist) -> PlaylistConfigValues {
        PlaylistConfigValues(
            name: playlist.name,
            serverURL: playlist.serverURL,
            username: playlist.username,
            password: playlist.password,
            sourceTypeRaw: playlist.sourceTypeRaw,
            epgURL: playlist.epgURL,
            syncEnabled: playlist.syncEnabled
        )
    }

    static func values(from mirror: SyncedPlaylist) -> PlaylistConfigValues {
        PlaylistConfigValues(
            name: mirror.name,
            serverURL: mirror.serverURL,
            username: mirror.username,
            password: mirror.password,
            sourceTypeRaw: mirror.sourceTypeRaw,
            epgURL: mirror.epgURL,
            syncEnabled: mirror.syncEnabled
        )
    }

    static func values(from mirror: UserContentState) -> ContentStateValues {
        ContentStateValues(
            watchProgress: mirror.watchProgress,
            isWatched: mirror.isWatched,
            lastWatchedDate: mirror.lastWatchedDate,
            isFavorite: mirror.isFavorite,
            addedToWatchlistDate: mirror.addedToWatchlistDate,
            favoriteOrder: mirror.favoriteOrder
        )
    }
}
