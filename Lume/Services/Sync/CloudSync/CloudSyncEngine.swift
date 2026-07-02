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
    var epgSourcesPushed = 0
    var epgSourcesPulled = 0
    /// Cloud states whose local catalog item hasn't synced yet — left pending
    /// (shadow untouched) so a later pass applies them once the catalog lands.
    var contentPending = 0
    /// Set when the pass was aborted because the local catalog store was
    /// unreadable (a fetch threw — a transient `no such table` detach or a
    /// corrupt store). No stores or shadow were touched; a later pass retries.
    var skippedUntrustworthyLocalStore = false
    /// Set when the local catalog came up empty after previously holding data (a
    /// lost or recreated `default.store`): the stale shadow was dropped so this
    /// pass pulls the surviving cloud records back instead of pushing deletions.
    var recoveredFromEmptyLocalStore = false
}

/// A local catalog item paired with its current syncable state, gathered up-front
/// so a reconcile pass touches the store once per type. `nonisolated` so the
/// engine actor can hold and read it off the main actor (the project defaults to
/// main-actor isolation, which would otherwise isolate this struct's members).
/// Not `private`: the profile operations in `CloudSyncEngine+Profiles.swift`
/// read its `kind` / `values`.
nonisolated struct LocalContentEntry {
    let values: ContentStateValues
    let kind: SyncedContentKind
    let model: any PersistentModel
}

/// Reconciles local SwiftData (the catalog + playlists) with the CloudKit-synced
/// mirror models (`SyncedPlaylist`, `UserContentState`) using the three-way
/// merge in `CloudSyncMerge`.
///
/// An `actor` that owns background `ModelContext`s — one per store, the same
/// pattern as `ContentSyncManager` / `WatchProgressWriter` — so all store work
/// stays off the main thread. Saves on these contexts auto-merge into their
/// container's main context, so `@Query`-driven UI updates after a pull, and a
/// newly pulled playlist trips `MainTabView`'s auto-sync to fetch its catalog.
///
/// Two contexts because the catalog and the CloudKit mirrors now live in separate
/// containers (so CloudKit's churn can't invalidate catalog `@Query`s). Each store
/// op routes to its own context; a reconcile saves both, then persists the shadow.
actor CloudSyncEngine {
    /// The local-only catalog store (Playlist, Movie, Series, Episode, LiveStream).
    let catalogContext: ModelContext
    /// The CloudKit-mirrored store (SyncedPlaylist, UserContentState, UserProfile).
    let cloudContext: ModelContext
    let shadow: CloudSyncShadow

    /// The profile whose state the catalog currently projects. Read from
    /// `ActiveProfileStore` at the start of each reconcile, so content state is
    /// pushed to / pulled from only this profile's mirror records; other
    /// profiles' records sync via CloudKit untouched until they become active.
    /// Not `private`: `CloudSyncEngine+Fetch.swift` reads it (`fetchContentMirrors`).
    var activeProfileID = UserProfile.defaultProfileID

    init(catalogContainer: ModelContainer, cloudContainer: ModelContainer, shadow: CloudSyncShadow = CloudSyncShadow()) {
        catalogContext = ModelContext(catalogContainer)
        catalogContext.autosaveEnabled = false
        cloudContext = ModelContext(cloudContainer)
        cloudContext.autosaveEnabled = false
        self.shadow = shadow
    }

    #if DEBUG
        /// Test/preview convenience: one container holding every model, shared by
        /// both store roles via a single background context — exactly the pre-split
        /// behavior. Production uses the two-container designated init above so
        /// CloudKit's churn can't invalidate the catalog; the reconcile/merge logic
        /// the tests exercise routes identically either way.
        init(container: ModelContainer, shadow: CloudSyncShadow = CloudSyncShadow()) {
            let ctx = ModelContext(container)
            ctx.autosaveEnabled = false
            catalogContext = ctx
            cloudContext = ctx
            self.shadow = shadow
        }
    #endif

    /// Run a full bidirectional reconcile: playlists first (so content can scope
    /// to the resulting live playlists), then per-content user state. Persists the
    /// shadow baseline and saves both stores at the end.
    @discardableResult
    func reconcile() -> CloudSyncReconcileResult {
        activeProfileID = ActiveProfileStore.current ?? UserProfile.defaultProfileID
        var result = CloudSyncReconcileResult()

        switch localCatalogReadiness() {
        case .ready:
            break
        case .unreadable:
            // The store is mid-detach or corrupt. Trust nothing: skip without
            // touching either store or the shadow, and retry on a later pass.
            result.skippedUntrustworthyLocalStore = true
            return result
        case .emptiedButHadData:
            // The catalog file was lost or recreated empty while the cloud and
            // the shadow survived. Drop the stale baseline so the merge below
            // pulls the surviving cloud records back into the catalog instead of
            // reading their absent local counterparts as deletions and wiping
            // every device. With an empty shadow every verdict is a pull — a
            // cloud-mirror deletion (`pushToCloud(nil)`) is now impossible.
            Logger.sync.error("Local catalog empty but shadow had baselines — recovering from cloud, dropping stale shadow (no deletions pushed)")
            shadow.reset()
            result.recoveredFromEmptyLocalStore = true
        }
        do {
            // Collapse any duplicate default profile a freshly-synced device
            // imported before its own bootstrap-created one could converge.
            try reconcileProfiles()
            let livePrefixes = try reconcilePlaylists(into: &result)
            try reconcileContent(livePrefixes: livePrefixes, into: &result)
            // Manual EPG sources sync as their own lightweight mirror; each
            // playlist's derived (linked) source is regenerated locally so it
            // appears on every device that has the playlist.
            try reconcileEPGSources(into: &result)
            regenerateLinkedEPGSources()
            // Two stores → two saves (`saveStores`, catalog first). Persist the
            // shadow only after both succeed, so a half-applied pass is never
            // baselined: if either save throws we fall to the catch, leave the
            // shadow untouched, and the next pass re-derives and re-applies (the
            // 3-way merge is idempotent).
            try saveStores()
            shadow.persist()
            Logger.sync.info("Reconcile pl +\(result.playlistsPushed) new \(result.playlistsCreatedLocally) ct +\(result.contentPushed)/\(result.contentPulled) pend \(result.contentPending) epg +\(result.epgSourcesPushed)/\(result.epgSourcesPulled)") // swiftlint:disable:this line_length
        } catch {
            Logger.sync.error("Reconcile failed: \(error.localizedDescription)")
        }
        return result
    }

    /// Persist pending changes in both stores, catalog first so a pulled cloud
    /// change lands locally before its mirror state is acknowledged. Callers that
    /// also persist the shadow must do so only after this returns without throwing.
    func saveStores() throws {
        if catalogContext.hasChanges { try catalogContext.save() }
        if cloudContext.hasChanges { try cloudContext.save() }
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
                if let mirror = mirrors[id] { cloudContext.delete(mirror) }
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

    // MARK: - Manual EPG sources

    /// Three-way-merges manual EPG sources (those with no owning playlist) with
    /// their cloud mirror, so a custom XMLTV feed added on one device reaches the
    /// others — and a fresh device that's never seen one pulls it in.
    private func reconcileEPGSources(into result: inout CloudSyncReconcileResult) throws {
        let localByID = try fetchLocalManualEPGSources()
        let mirrorsByID = try fetchEPGSourceMirrors()

        var ids = Set(localByID.keys).union(mirrorsByID.keys)
        ids.formUnion(shadow.epgSourceShadowIDs().compactMap(UUID.init(uuidString:)))

        for id in ids {
            let verdict = CloudSyncMerge.reconcile(
                local: localByID[id].map(Self.values(from:)),
                cloud: mirrorsByID[id].map(Self.values(from:)),
                shadow: shadow.epgSourceShadow(id.uuidString),
                mergeConflict: EPGSourceValues.mergeConflict
            )
            applyEPGSourceVerdict(verdict, id: id, local: localByID[id], mirror: mirrorsByID[id], into: &result)
        }
    }

    /// Rebuilds each playlist's derived (linked) EPG source from its current
    /// config, so a playlist pulled in from iCloud gets its guide source on this
    /// device too. Idempotent — only writes when something actually changed.
    private func regenerateLinkedEPGSources() {
        guard let playlists = try? catalogContext.fetch(FetchDescriptor<Playlist>()) else { return }
        // One source fetch for the whole pass — `apply(_:in:)` would re-fetch
        // the source table once per playlist, on every reconcile.
        let linked = EPGSourceReconciler.linkedSourcesByPlaylist(in: catalogContext)
        for playlist in playlists {
            EPGSourceReconciler.apply(playlist, existing: linked[playlist.id], in: catalogContext)
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

    func applyEPGSourceVerdict(
        _ verdict: MergeVerdict<EPGSourceValues>,
        id: UUID,
        local: EPGSource?,
        mirror: SyncedEPGSource?,
        into result: inout CloudSyncReconcileResult
    ) {
        let key = id.uuidString
        switch verdict {
        case .noChange:
            break
        case let .pushToCloud(value):
            applyEPGSourceToCloud(value, id: id, mirror: mirror)
            if value != nil { result.epgSourcesPushed += 1 }
            shadow.setEPGSourceShadow(key, value)
        case let .pullToLocal(value):
            applyEPGSourceToLocal(value, id: id, local: local)
            if value != nil { result.epgSourcesPulled += 1 }
            shadow.setEPGSourceShadow(key, value)
        case let .writeBoth(value):
            applyEPGSourceToCloud(value, id: id, mirror: mirror)
            applyEPGSourceToLocal(value, id: id, local: local)
            result.epgSourcesPushed += 1
            shadow.setEPGSourceShadow(key, value)
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
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        if let mirror {
            mirror.name = value.name
            mirror.serverURL = value.serverURL
            mirror.username = value.username
            mirror.password = value.password
            mirror.macAddress = value.macAddress
            mirror.sourceTypeRaw = value.sourceTypeRaw
            mirror.epgURL = value.epgURL
            mirror.syncEnabled = value.syncEnabled
            mirror.updatedAt = Date()
        } else {
            cloudContext.insert(SyncedPlaylist(
                id: id,
                name: value.name,
                serverURL: value.serverURL,
                username: value.username,
                password: value.password,
                macAddress: value.macAddress,
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
            // Mirror the local-deletion path: remove the playlist's orphaned
            // catalog content too, not just the `Playlist` row.
            if let local { PlaylistDeletion.delete(local, in: catalogContext) }
            return false
        }
        if let local {
            local.name = value.name
            local.serverURL = value.serverURL
            local.username = value.username
            local.password = value.password
            local.macAddress = value.macAddress.isEmpty ? nil : value.macAddress
            local.sourceTypeRaw = value.sourceTypeRaw
            local.epgURL = value.epgURL
            local.syncEnabled = value.syncEnabled
            return false
        }
        let playlist = Playlist(name: value.name, serverURL: value.serverURL, username: value.username, password: value.password)
        playlist.id = id
        playlist.macAddress = value.macAddress.isEmpty ? nil : value.macAddress
        playlist.sourceTypeRaw = value.sourceTypeRaw
        playlist.epgURL = value.epgURL
        playlist.syncEnabled = value.syncEnabled
        catalogContext.insert(playlist)
        return true
    }

    func applyEPGSourceToCloud(_ value: EPGSourceValues?, id: UUID, mirror: SyncedEPGSource?) {
        guard let value else {
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        if let mirror {
            mirror.name = value.name
            mirror.url = value.url
            mirror.isEnabled = value.isEnabled
            mirror.updatedAt = Date()
        } else {
            cloudContext.insert(SyncedEPGSource(id: id, name: value.name, url: value.url, isEnabled: value.isEnabled))
        }
    }

    func applyEPGSourceToLocal(_ value: EPGSourceValues?, id: UUID, local: EPGSource?) {
        guard let value else {
            if let local { catalogContext.delete(local) }
            return
        }
        if let local {
            local.name = value.name
            local.url = value.url
            local.isEnabled = value.isEnabled
        } else {
            let source = EPGSource(name: value.name, url: value.url, playlistID: nil)
            source.id = id
            source.isEnabled = value.isEnabled
            catalogContext.insert(source)
        }
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

/// Not `private`: profile operations in `CloudSyncEngine+Profiles.swift`
/// reuse these helpers (fetch / reset / apply / value extraction).
extension CloudSyncEngine {
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
            if let mirror { cloudContext.delete(mirror) }
            return
        }
        let kind = kind ?? mirror?.kind ?? .movie
        if let mirror {
            mirror.profileID = activeProfileID // heals a legacy nil record on first touch
            mirror.kindRaw = kind.rawValue
            mirror.watchProgress = value.watchProgress
            mirror.isWatched = value.isWatched
            mirror.lastWatchedDate = value.lastWatchedDate
            mirror.isFavorite = value.isFavorite
            mirror.addedToWatchlistDate = value.addedToWatchlistDate
            mirror.favoriteOrder = value.favoriteOrder
            mirror.recommendationVoteRaw = value.recommendationVoteRaw
            mirror.updatedAt = Date()
        } else {
            cloudContext.insert(UserContentState(
                contentId: id,
                kind: kind,
                profileID: activeProfileID,
                watchProgress: value.watchProgress,
                isWatched: value.isWatched,
                lastWatchedDate: value.lastWatchedDate,
                isFavorite: value.isFavorite,
                addedToWatchlistDate: value.addedToWatchlistDate,
                favoriteOrder: value.favoriteOrder,
                recommendationVoteRaw: value.recommendationVoteRaw
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
            movie.recommendationVoteRaw = values.recommendationVoteRaw
        case .series:
            guard let series = try (loaded as? Series) ?? fetchSeries(id) else { return false }
            series.isFavorite = values.isFavorite
            series.addedToWatchlistDate = values.addedToWatchlistDate
            series.lastWatchedDate = values.lastWatchedDate
            series.recommendationVoteRaw = values.recommendationVoteRaw
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
            movie.recommendationVoteRaw = 0
        case let series as Series:
            series.isFavorite = false
            series.addedToWatchlistDate = nil
            series.lastWatchedDate = nil
            series.recommendationVoteRaw = 0
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
