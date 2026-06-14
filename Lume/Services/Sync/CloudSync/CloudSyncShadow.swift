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

    private var playlists: [String: PlaylistConfigValues]
    private var content: [String: ContentStateValues]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playlists = Self.decode(defaults.data(forKey: playlistsKey)) ?? [:]
        content = Self.decode(defaults.data(forKey: contentKey)) ?? [:]
    }

    // MARK: Playlists (keyed by UUID string)

    func playlistShadow(_ id: String) -> PlaylistConfigValues? {
        playlists[id]
    }

    func setPlaylistShadow(_ id: String, _ value: PlaylistConfigValues?) {
        playlists[id] = value
    }

    func playlistShadowIDs() -> Set<String> {
        Set(playlists.keys)
    }

    // MARK: Content (keyed by content id)

    func contentShadow(_ id: String) -> ContentStateValues? {
        content[id]
    }

    func setContentShadow(_ id: String, _ value: ContentStateValues?) {
        content[id] = value
    }

    func contentShadowIDs() -> Set<String> {
        Set(content.keys)
    }

    /// Drop the entire content baseline. Called on a profile switch: the catalog
    /// has been re-projected to a different profile, so the previous baseline no
    /// longer describes it. The next reconcile rebuilds it (a one-time union
    /// merge — never data loss, per this type's contract).
    func resetContent() {
        content.removeAll()
    }

    // MARK: Persistence

    /// Flush the in-memory baseline to disk. Called once at the end of a
    /// reconcile pass.
    func persist() {
        defaults.set(Self.encode(playlists), forKey: playlistsKey)
        defaults.set(Self.encode(content), forKey: contentKey)
    }

    private static func encode(_ value: some Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
