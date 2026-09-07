import Foundation
import SwiftData

@Model
final class LiveStream {
    // Live TV's Favorites / Recently Watched rows and the iCloud reconciler
    // filter channels by these columns; index them so a foreground refresh
    // seeks instead of scanning every channel on the main thread.
    // Selecting a Live TV category filters on `categoryId` (the single most
    // common Live TV query). Index it — and pair it with `isHidden`, which the
    // category predicate also tests — so a tap seeks the category's channels
    // instead of scanning every channel in a large playlist.
    // The standalone `isHidden` index serves the reconciler's export fetch
    // (`isFavorite || isHidden`): SQLite's OR optimization needs each disjunct
    // independently indexed, and the composite above can't serve `isHidden`
    // without a `categoryId` prefix — without it every reconcile scans the
    // whole channel table.
    #Index<LiveStream>(
        [\.isFavorite],
        [\.lastWatchedDate],
        [\.categoryId],
        [\.categoryId, \.isHidden],
        [\.isHidden]
    )

    @Attribute(.unique) var id: String
    var streamId: Int
    var name: String
    var streamIcon: String?
    var epgChannelId: String?
    var added: String?
    var customSid: String?
    var tvArchive: Int
    var tvArchiveDuration: Int
    /// The catch-up dialect an m3u playlist declared for this channel
    /// (`catchup="…"`), folded to its canonical spelling by the importer, which
    /// writes it only for a dialect it can build a URL for. Optional and outside
    /// `#Index` on purpose: the app ships without a `SchemaMigrationPlan`, so
    /// every new column has to stay lightweight-migratable.
    var catchupTypeRaw: String?
    /// The verbatim `catchup-source` template. Expanded at play time, never at
    /// import time — expanding on import would bake in a stale `now`.
    var catchupSource: String?
    var isAdult: Int
    var num: Int

    var categoryId: String?

    /// Full playback URL for streams that come from an m3u playlist. When set,
    /// playback uses it verbatim instead of building an Xtream URL from
    /// credentials and `streamId` (which is a derived hash for m3u sources).
    var directURL: String?

    var isFavorite: Bool = false
    var lastWatchedDate: Date?
    /// Hidden channels are kept in the store but excluded from browsing. Toggled
    /// from Content Management.
    var isHidden: Bool = false
    /// A user-defined order set in Content Management. `nil` means "follow the
    /// provider order" (`num`); once reordered, every channel in the category
    /// gets a dense value so it survives re-syncs.
    var customOrder: Int?
    /// A user-defined order for the Favorites collection, independent of the
    /// per-category `customOrder`. `nil` means "follow the provider order"; once
    /// the favorites are reordered in Content Management, every favorite gets a
    /// dense value so the arrangement survives re-syncs. Kept separate from
    /// `customOrder` because a channel's place among its category's channels and
    /// its place in the Favorites list are independent.
    var favoriteOrder: Int?

    init(
        id: String,
        streamId: Int,
        name: String,
        streamIcon: String? = nil,
        epgChannelId: String? = nil,
        added: String? = nil,
        customSid: String? = nil,
        tvArchive: Int = 0,
        tvArchiveDuration: Int = 0,
        isAdult: Int = 0,
        num: Int = 0,
        categoryId: String? = nil,
        catchupTypeRaw: String? = nil,
        catchupSource: String? = nil
    ) {
        self.id = id
        self.streamId = streamId
        self.name = name
        self.streamIcon = streamIcon
        self.epgChannelId = epgChannelId
        self.added = added
        self.customSid = customSid
        self.tvArchive = tvArchive
        self.tvArchiveDuration = tvArchiveDuration
        self.isAdult = isAdult
        self.num = num
        self.categoryId = categoryId
        self.catchupTypeRaw = catchupTypeRaw
        self.catchupSource = catchupSource
    }
}

extension LiveStream {
    /// The catch-up dialect declared for this channel, or `nil` when the
    /// playlist declared none or one we cannot build a URL for.
    var catchupType: CatchupType? {
        get { CatchupType.parse(catchupTypeRaw) }
        set { catchupTypeRaw = newValue?.rawValue }
    }
}

/// The catch-up (archive) dialects an m3u playlist can declare through
/// `catchup="…"`. Raw values are the canonical spellings; `parse` folds in the
/// aliases seen in the wild.
nonisolated enum CatchupType: String {
    case `default`
    case append
    case flussonic
    // swiftlint:disable:next identifier_name - `xc` is the spelling playlists ship.
    case xc
    case shift
}

nonisolated extension CatchupType {
    /// Tolerant of the spellings playlists actually ship: `fs`, `flussonic-hls`,
    /// `xtream`, and the bare enable-flags `1`/`true` used by `tvg-rec`. The
    /// hls-flavoured Flussonic spellings fold into `flussonic`: the archive URL
    /// is the same filename rewrite, and the container stays whatever the live
    /// URL already carried.
    static func parse(_ raw: String?) -> CatchupType? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = CatchupType(rawValue: key) { return exact }
        switch key {
        case "fs", "flussonic-hls", "flussonic_hls", "flussonichls": return .flussonic
        case "xtream", "xtreamcodes", "xtream-codes": return .xc
        case "timeshift": return .shift
        default: return isEnableFlag(key) ? .default : nil
        }
    }

    /// The truthy spellings `tvg-rec` uses to declare an archive without naming
    /// a dialect. Shared with `M3UParser` so the parser and the model can never
    /// disagree on what counts as "on".
    static func isEnableFlag(_ raw: String) -> Bool {
        enableFlags.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static let enableFlags: Set<String> = ["1", "true", "yes"]
}
