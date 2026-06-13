import Foundation
import SwiftData

/// CloudKit-synced mirror of a `Playlist`'s user-configurable identity.
///
/// The catalog (`Movie`, `Series`, `Episode`, …) is *not* synced — it is large,
/// re-derivable from the provider, and uses `@Attribute(.unique)` which CloudKit
/// forbids. Instead this lightweight record carries only what a fresh device
/// needs to reconstruct a playlist; once it lands, the existing auto-sync path
/// fetches that playlist's catalog locally.
///
/// `id` matches the local `Playlist.id` verbatim. Because every catalog id
/// embeds the owning playlist's UUID (`"<playlistUUID>-movie-<streamId>"` etc.),
/// preserving the UUID across devices is what lets per-content user state
/// (`UserContentState`) reconcile by id without any cross-device lookup table.
///
/// CloudKit constraints honoured here: every stored property is optional or has
/// a default, there is no `@Attribute(.unique)`, and there are no relationships.
/// Credentials use `.allowsCloudEncryption` so they ride the private database
/// end-to-end encrypted rather than as plaintext record fields.
@Model
final class SyncedPlaylist {
    /// Mirrors `Playlist.id`. Not unique (CloudKit can't enforce uniqueness) —
    /// the reconciler dedupes by this value itself.
    var id: UUID = UUID()
    var name: String = ""
    var serverURL: String = ""

    @Attribute(.allowsCloudEncryption) var username: String = ""
    @Attribute(.allowsCloudEncryption) var password: String = ""

    var sourceTypeRaw: String = PlaylistSourceType.xtream.rawValue
    var epgURL: String?
    var syncEnabled: Bool = true

    /// Last time this record's config fields changed. Informational (surfaced in
    /// diagnostics / "last write wins" tie-breaks); the reconciler's correctness
    /// rests on the shadow baseline, not on this clock.
    var updatedAt: Date = Date()

    init(
        id: UUID,
        name: String,
        serverURL: String,
        username: String,
        password: String,
        sourceTypeRaw: String,
        epgURL: String?,
        syncEnabled: Bool,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.sourceTypeRaw = sourceTypeRaw
        self.epgURL = epgURL
        self.syncEnabled = syncEnabled
        self.updatedAt = updatedAt
    }
}
