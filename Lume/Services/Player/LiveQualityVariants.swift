import Foundation
import SwiftData

/// One quality of the playing live channel, as the player's Quality menu
/// lists it.
nonisolated struct LiveQualityVariantOption: Identifiable, Equatable {
    /// The `LiveStream.id` of this variant.
    let id: String
    /// The quality tag as the provider wrote it ("4K", "FHD", "ᴴᴰ"), or `nil`
    /// for an untagged sibling.
    let tag: String?
    /// The provider's full channel name.
    let name: String
    let quality: ChannelQuality?
    let target: PlayableMedia
}

/// Finds the other qualities a playlist lists the playing live channel in:
/// every channel of the same playlist whose `ChannelQuality` key equals the
/// playing one's, wherever its category.
nonisolated enum LiveQualityVariants {
    /// A bound on the candidate rows, which the name filter has already
    /// narrowed to channels sharing the key's most distinctive words.
    static let fetchLimit = 200

    /// The playing channel's variants, best quality first, or `[]` when
    /// `media` isn't a live channel (catch-up and timeshift included) or the
    /// playlist offers no second quality. Each target is anchored at the
    /// channel the viewer tuned to.
    @concurrent
    static func resolve(
        for media: PlayableMedia,
        restriction: ContentRestriction,
        container: ModelContainer
    ) async -> [LiveQualityVariantOption] {
        guard media.kind == .live else { return [] }
        return resolve(for: media, restriction: restriction, in: ModelContext(container))
    }

    static func resolve(
        for media: PlayableMedia,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> [LiveQualityVariantOption] {
        guard media.kind == .live, case let .live(currentID) = media.contentRef else { return [] }
        guard let current = PlayerContentLookup.liveStream(currentID, in: context),
              !restriction.hides(categoryID: current.categoryId),
              let playlist = LiveChannelNavigator.playlist(for: current, in: context) else { return [] }

        let currentParsed = ChannelQuality.parse(current.name)
        let key = currentParsed.key
        let words = searchWords(in: key)
        guard !words.isEmpty else { return [] }
        let prefix = "\(playlist.id.uuidString)-"
        // Optionals so the predicate can test the optional `categoryId` against
        // them directly — see `LiveChannelNavigator.scopeDescriptor`.
        let excluded = Set(restriction.excludedCategoryIDs.map(String?.some))

        var descriptor = FetchDescriptor<LiveStream>(
            predicate: candidatePredicate(prefix: prefix, excluded: excluded, words: words)
        )
        descriptor.fetchLimit = fetchLimit
        var rows = ((try? context.fetch(descriptor)) ?? [])
            .map { (stream: $0, parsed: ChannelQuality.parse($0.name)) }
            .filter { $0.parsed.key == key }
        if !rows.contains(where: { $0.stream.id == currentID }) {
            rows.append((stream: current, parsed: currentParsed))
        }
        guard rows.count >= 2 else { return [] }

        let anchor = media.qualityAnchorID ?? currentID
        let client = XtreamClient()
        let options = rows.compactMap { row -> LiveQualityVariantOption? in
            guard let target = PlayableMedia.from(
                stream: row.stream, playlist: playlist, scope: media.channelScope, surfScope: media.surfScope, client: client
            ) else { return nil }
            return LiveQualityVariantOption(
                id: row.stream.id,
                tag: row.parsed.tag,
                name: row.stream.name,
                quality: row.parsed.quality,
                target: target.asQualityVariant(anchoredAt: anchor)
            )
        }
        guard options.count >= 2 else { return [] }
        return options.sorted(by: precedes)
    }

    /// The key's four longest alphanumeric words, longest first, numbers
    /// included so "Lume Sport 1" doesn't pull in every "Lume Sport" row before
    /// the fetch limit. Each one appears in every name that parses to the key,
    /// up to case and diacritics, which `localizedStandardContains` ignores.
    static func searchWords(in key: String) -> [String] {
        let words = key.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var seen = Set<String>()
        return words
            .filter { seen.insert($0).inserted }
            .enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .prefix(4)
            .map(\.element)
    }

    /// One `localizedStandardContains` term per distinct word: the scan can
    /// use no index, so a repeated term costs a full pass over every row.
    private static func candidatePredicate(
        prefix: String,
        excluded: Set<String?>,
        words: [String]
    ) -> Predicate<LiveStream> {
        let filters = !excluded.isEmpty
        switch words.count {
        case 1:
            let first = words[0]
            return #Predicate { stream in
                stream.id.starts(with: prefix)
                    && stream.isHidden == false
                    && (!filters || !excluded.contains(stream.categoryId))
                    && stream.name.localizedStandardContains(first)
            }
        case 2:
            let first = words[0], second = words[1]
            return #Predicate { stream in
                stream.id.starts(with: prefix)
                    && stream.isHidden == false
                    && (!filters || !excluded.contains(stream.categoryId))
                    && stream.name.localizedStandardContains(first)
                    && stream.name.localizedStandardContains(second)
            }
        case 3:
            let first = words[0], second = words[1], third = words[2]
            return #Predicate { stream in
                stream.id.starts(with: prefix)
                    && stream.isHidden == false
                    && (!filters || !excluded.contains(stream.categoryId))
                    && stream.name.localizedStandardContains(first)
                    && stream.name.localizedStandardContains(second)
                    && stream.name.localizedStandardContains(third)
            }
        default:
            let first = words[0], second = words[1], third = words[2], fourth = words[3]
            return #Predicate { stream in
                stream.id.starts(with: prefix)
                    && stream.isHidden == false
                    && (!filters || !excluded.contains(stream.categoryId))
                    && stream.name.localizedStandardContains(first)
                    && stream.name.localizedStandardContains(second)
                    && stream.name.localizedStandardContains(third)
                    && stream.name.localizedStandardContains(fourth)
            }
        }
    }

    private static func precedes(_ lhs: LiveQualityVariantOption, _ rhs: LiveQualityVariantOption) -> Bool {
        let lhsQuality = lhs.quality ?? .sd, rhsQuality = rhs.quality ?? .sd
        if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }
}
