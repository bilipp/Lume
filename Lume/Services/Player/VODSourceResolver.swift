//
//  VODSourceResolver.swift
//  Lume
//
//  Every catalog row of one movie or series title the viewer can play: the
//  copies across qualities, languages and playlists that grouped into one card.
//  Each row stays its own source and plays through the playlist that owns it.
//

import Foundation
import SwiftData

/// One playable copy of a title, as the source picker lists it.
nonisolated struct VODSourceOption: Identifiable, Hashable {
    /// The catalog row's id (`<playlistUUID>-movie-…` / `-series-…`).
    let rowID: String
    let playlistID: UUID
    let playlistName: String
    /// The title as this row's playlist lists it, tags and prefixes included.
    let title: String
    /// 4K, UHD, FHD, HD or SD; nil when the provider's title names none.
    let qualityLabel: String?
    let isHDR: Bool
    let isDolbyVision: Bool
    /// Bare ISO 639-1 code from the title, else from the category name.
    let languageCode: String?
    let categoryName: String?
    /// A Jellyfin, Emby or Plex row: one entry here, its versions are picked
    /// later by the player's own media-source flow.
    let isMediaServer: Bool

    var id: String {
        rowID
    }
}

nonisolated enum VODSourceResolver {
    /// Every row of `row`'s title in `scope`, `row` included, best first.
    /// `playlists` is every installed playlist; nil fetches them.
    static func sources<Row: TitleSiblingRow>(
        for row: Row,
        scope: CatalogScope,
        restriction: ContentRestriction = ContentRestriction(),
        isPremium: Bool,
        playlists: [Playlist]? = nil,
        in context: ModelContext,
        preferredLanguages: [String] = PlayerLanguageOptions.load().preferredAudioLanguages
    ) -> [VODSourceOption] {
        let viewer = Viewer(scope: scope, restriction: restriction, isPremium: isPremium, preferredLanguages: preferredLanguages)
        let installed = playlists ?? (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return options(
            current: row,
            siblings: TitleGroupSiblings.others(of: row, in: context),
            tab: Row.playlistTab,
            playlists: installed,
            for: viewer,
            in: context
        )
    }
}

private nonisolated extension VODSourceResolver {
    /// What decides which rows the viewer gets and in which order.
    struct Viewer {
        let scope: CatalogScope
        let restriction: ContentRestriction
        let isPremium: Bool
        let preferredLanguages: [String]
    }

    struct Candidate {
        let option: VODSourceOption
        let playlistRank: Int
        let rank: VariantTags.Rank
    }

    /// The row on screen is kept whatever the scope or restriction says (the
    /// viewer is already looking at it); siblings must belong to a member of
    /// `scope` contributing `tab`, or to the current row's own playlist, and sit
    /// in a category the viewer may see. Rows on a playlist the plan locks, or
    /// that no installed playlist owns, are dropped: there is nothing to play
    /// them with.
    static func options<Row: TitleGroupedRow>( // swiftlint:disable:this function_parameter_count
        current: Row,
        siblings: [Row],
        tab: PlaylistTab,
        playlists: [Playlist],
        for viewer: Viewer,
        in context: ModelContext
    ) -> [VODSourceOption] {
        let unlocked = playlists.unlocked(premium: viewer.isPremium)
        let byID = Dictionary(unlocked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentOwner = PlaylistOwner.declaredOwner(of: current.id)
        let members = viewer.scope.members(for: tab)

        var rows = [current]
        var seen: Set<String> = [current.id]
        for row in siblings where seen.insert(row.id).inserted {
            guard let owner = PlaylistOwner.declaredOwner(of: row.id),
                  owner == currentOwner || members.contains(owner),
                  !viewer.restriction.hides(categoryID: row.categoryId)
            else { continue }
            rows.append(row)
        }

        let categoryNames = categoryNames(for: rows, in: context)
        let candidates: [Candidate] = rows.compactMap { row in
            guard let owner = PlaylistOwner.declaredOwner(of: row.id), let playlist = byID[owner] else { return nil }
            let categoryName = row.categoryId.flatMap { categoryNames[$0] }
            let tags = VariantTags(title: row.name, categoryName: categoryName)
            let option = VODSourceOption(
                rowID: row.id,
                playlistID: owner,
                playlistName: playlist.name,
                title: row.name,
                qualityLabel: tags.qualityLabel,
                isHDR: tags.isHDR,
                isDolbyVision: tags.isDolbyVision,
                languageCode: tags.languageCode,
                categoryName: categoryName,
                isMediaServer: PlaylistSourceType(rawValue: playlist.sourceTypeRaw)?.isMediaServer == true
            )
            let playlistRank = members.firstIndex(of: owner) ?? (owner == currentOwner ? -1 : members.count)
            return Candidate(option: option, playlistRank: playlistRank, rank: tags.rank(preferredLanguages: viewer.preferredLanguages))
        }
        return candidates.sorted(by: precedes).map(\.option)
    }

    /// Playlist priority, then preferred audio language, then quality.
    static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.playlistRank != rhs.playlistRank { return lhs.playlistRank < rhs.playlistRank }
        if lhs.rank.language != rhs.rank.language { return lhs.rank.language < rhs.rank.language }
        if lhs.rank.quality != rhs.rank.quality { return lhs.rank.quality > rhs.rank.quality }
        return lhs.option.rowID < rhs.option.rowID
    }

    static func categoryNames(for rows: [some TitleGroupedRow], in context: ModelContext) -> [String: String] {
        let ids = Set(rows.compactMap(\.categoryId))
        guard !ids.isEmpty else { return [:] }
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        return Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
