import Foundation
import SwiftData

/// CloudKit-synced mirror of a *manual* `EPGSource` (one the user added in EPG
/// settings, with no owning playlist).
///
/// Playlist-linked sources are **not** mirrored: they're derived from a
/// `Playlist`, which already syncs via `SyncedPlaylist`, so every device
/// regenerates them locally through `EPGSourceReconciler` once the playlist
/// lands. Only manual sources carry no playlist behind them and so need their
/// own record to reach a fresh device.
///
/// `id` matches the local `EPGSource.id` verbatim. CloudKit constraints honoured:
/// every stored property is optional or defaulted, there is no `@Attribute(.unique)`,
/// and there are no relationships.
@Model
final class SyncedEPGSource {
    /// Mirrors `EPGSource.id`. Not unique (CloudKit can't enforce it) — the
    /// reconciler dedupes by this value itself.
    var id: UUID = UUID()
    var name: String = ""
    var url: String = ""
    var isEnabled: Bool = true

    /// Last time this record's fields changed. Informational / dedupe tie-break;
    /// the reconciler's correctness rests on the shadow baseline, not this clock.
    var updatedAt: Date = Date()

    init(id: UUID, name: String, url: String, isEnabled: Bool, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}
