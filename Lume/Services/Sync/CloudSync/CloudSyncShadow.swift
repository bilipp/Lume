import Foundation

/// The "last-synced agreed value" baseline that powers the three-way merge in
/// `CloudSyncMerge`. For each playlist and each content item it remembers the
/// value local and cloud last converged on, so the next reconcile can tell an
/// *edit* from a *delete* on either side.
///
/// Persisted to `UserDefaults` as JSON. It is metadata, not user content — if it
/// is ever lost the reconciler degrades gracefully to a one-time union merge
/// (briefly treating both sides as "changed"), never data loss.
///
/// Owned exclusively by `CloudSyncEngine` (an actor), so it needs no internal
/// locking; `nonisolated` only frees it from the project's default main-actor
/// isolation so the engine can hold and mutate it off the main thread.
final nonisolated class CloudSyncShadow {
    private let defaults: UserDefaults
    private let playlistsKey = "cloudsync.shadow.playlists.v1"
    private let contentKey = "cloudsync.shadow.content.v1"
    private let epgSourcesKey = "cloudsync.shadow.epgsources.v1"
    private let parentalPINKey = "cloudsync.shadow.parentalpin.v1"
    private let categoryRestrictionsKey = "cloudsync.shadow.categoryrestrictions.v1"

    private var playlists: [String: PlaylistConfigValues]
    private var content: [String: ContentStateValues]
    private var epgSources: [String: EPGSourceValues]
    /// Single-valued (the PIN is a singleton), so it is stored bare rather than
    /// in a dictionary. `nil` means "no PIN last time we looked".
    private var parentalPIN: ParentalPINValues?
    private var categoryRestrictions: [String: CategoryRestrictionValues]

    /// Set whenever a setter actually changes the baseline; cleared on `persist()`.
    /// A steady-state reconcile (every verdict `.noChange`) mutates nothing, so
    /// `persist()` then skips re-encoding the entire baseline to JSON for no gain.
    private var isDirty = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playlists = Self.decode(defaults.data(forKey: playlistsKey)) ?? [:]
        content = Self.decode(defaults.data(forKey: contentKey)) ?? [:]
        epgSources = Self.decode(defaults.data(forKey: epgSourcesKey)) ?? [:]
        parentalPIN = Self.decode(defaults.data(forKey: parentalPINKey))
        categoryRestrictions = Self.decode(defaults.data(forKey: categoryRestrictionsKey)) ?? [:]
    }

    // MARK: Playlists (keyed by UUID string)

    func playlistShadow(_ id: String) -> PlaylistConfigValues? {
        playlists[id]
    }

    func setPlaylistShadow(_ id: String, _ value: PlaylistConfigValues?) {
        guard playlists[id] != value else { return }
        playlists[id] = value
        isDirty = true
    }

    func playlistShadowIDs() -> Set<String> {
        Set(playlists.keys)
    }

    // MARK: Content (keyed by content id)

    func contentShadow(_ id: String) -> ContentStateValues? {
        content[id]
    }

    func setContentShadow(_ id: String, _ value: ContentStateValues?) {
        guard content[id] != value else { return }
        content[id] = value
        isDirty = true
    }

    func contentShadowIDs() -> Set<String> {
        Set(content.keys)
    }

    // MARK: Manual EPG sources (keyed by UUID string)

    func epgSourceShadow(_ id: String) -> EPGSourceValues? {
        epgSources[id]
    }

    func setEPGSourceShadow(_ id: String, _ value: EPGSourceValues?) {
        guard epgSources[id] != value else { return }
        epgSources[id] = value
        isDirty = true
    }

    func epgSourceShadowIDs() -> Set<String> {
        Set(epgSources.keys)
    }

    // MARK: Parental controls

    func parentalPINShadow() -> ParentalPINValues? {
        parentalPIN
    }

    func setParentalPINShadow(_ value: ParentalPINValues?) {
        guard parentalPIN != value else { return }
        parentalPIN = value
        isDirty = true
    }

    // MARK: Category restrictions (keyed by `Category.id`)

    func categoryRestrictionShadow(_ id: String) -> CategoryRestrictionValues? {
        categoryRestrictions[id]
    }

    func setCategoryRestrictionShadow(_ id: String, _ value: CategoryRestrictionValues?) {
        guard categoryRestrictions[id] != value else { return }
        categoryRestrictions[id] = value
        isDirty = true
    }

    func categoryRestrictionShadowIDs() -> Set<String> {
        Set(categoryRestrictions.keys)
    }

    /// Drop the entire content baseline. Called on a profile switch: the catalog
    /// has been re-projected to a different profile, so the previous baseline no
    /// longer describes it. The next reconcile rebuilds it (a one-time union
    /// merge — never data loss, per this type's contract).
    ///
    /// Deliberately leaves the parental baselines alone: neither the PIN nor
    /// category restrictions are profile-scoped, so a profile switch doesn't
    /// change what they describe.
    func resetContent() {
        guard !content.isEmpty else { return }
        content.removeAll()
        isDirty = true
    }

    /// Drop the entire baseline — both playlists and content. Called when the
    /// local catalog store has come up empty after previously holding data (a
    /// lost or recreated `default.store`): with no baseline, the next reconcile
    /// reads the surviving cloud records as values to *pull back*, never as local
    /// deletions to push — so a vanished store recovers from the cloud instead of
    /// wiping it. Safe by this type's contract (degrades to a one-time union
    /// merge, never data loss).
    func reset() {
        guard !playlists.isEmpty || !content.isEmpty || !epgSources.isEmpty
            || !categoryRestrictions.isEmpty else { return }
        playlists.removeAll()
        content.removeAll()
        epgSources.removeAll()
        // Category restrictions are catalog-derived (their local side is
        // `Category.isRestricted`), so a vanished catalog makes their baseline as
        // stale as the content one.
        categoryRestrictions.removeAll()
        // The PIN baseline is deliberately *kept*. Its local side is the
        // keychain, which a lost `default.store` doesn't touch, so the baseline
        // still describes reality. Dropping it would turn "the parent removed the
        // PIN on another device" (local hash, cloud empty, no baseline) into a
        // local edit to push — re-arming the very PIN the shadow exists to let
        // us delete.
        isDirty = true
    }

    // MARK: Persistence

    /// Flush the in-memory baseline to disk. Called once at the end of a
    /// reconcile pass; a no-op when nothing changed since the last flush, so a
    /// steady-state pass doesn't re-encode the whole baseline to JSON.
    func persist() {
        guard isDirty else { return }
        defaults.set(Self.encode(playlists), forKey: playlistsKey)
        defaults.set(Self.encode(content), forKey: contentKey)
        defaults.set(Self.encode(epgSources), forKey: epgSourcesKey)
        defaults.set(Self.encode(categoryRestrictions), forKey: categoryRestrictionsKey)
        // Stored bare rather than wrapped, so "no PIN" is the absence of the key
        // rather than an encoded `null` — `JSONEncoder` rejects a top-level nil.
        // Both read back as `nil`, and for this baseline "never synced" and "no
        // PIN agreed" are the same state, so nothing is lost by collapsing them.
        if let parentalPIN {
            defaults.set(Self.encode(parentalPIN), forKey: parentalPINKey)
        } else {
            defaults.removeObject(forKey: parentalPINKey)
        }
        isDirty = false
    }

    private static func encode(_ value: some Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
