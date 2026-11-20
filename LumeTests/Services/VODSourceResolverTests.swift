//
//  VODSourceResolverTests.swift
//  LumeTests
//
//  The source picker's view of a grouped title: every playable copy in the
//  scope, ordered by playlist priority, preferred language and quality; the
//  rules for skipping the picker; and the device-local remembered pick.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct VODSourceResolverTests {
    private func makePlaylist(name: String, addedAt: TimeInterval = 1_700_000_000, in context: ModelContext) -> Playlist {
        let playlist = Playlist(name: name, serverURL: "http://x.com", username: "u", password: "p")
        playlist.addedAt = Date(timeIntervalSince1970: addedAt)
        context.insert(playlist)
        return playlist
    }

    private func makeMovie(
        _ playlist: Playlist,
        _ streamId: Int,
        name: String? = nil,
        tmdbId: Int?,
        categoryId: String? = nil,
        in context: ModelContext
    ) -> Movie {
        let movie = Movie(id: "\(playlist.id.uuidString)-movie-\(streamId)", streamId: streamId, name: name ?? "Movie \(streamId)")
        movie.tmdbId = tmdbId
        movie.categoryId = categoryId
        movie.titleGroupKey = TitleGroupKey.movie(tmdbId: tmdbId, name: movie.name)
        context.insert(movie)
        return movie
    }

    private func makeSeries(_ playlist: Playlist, _ seriesId: Int, tmdbId: Int?, in context: ModelContext) -> Series {
        let series = Series(id: "\(playlist.id.uuidString)-series-\(seriesId)", seriesId: seriesId, name: "Series \(seriesId)")
        series.tmdbId = tmdbId
        series.titleGroupKey = TitleGroupKey.series(tmdbId: tmdbId, name: series.name)
        context.insert(series)
        return series
    }

    private func combined(_ playlists: Playlist...) -> CatalogScope {
        .combined(playlists.map { (id: $0.id, tabs: Set(PlaylistTab.allCases)) })
    }

    private func movieSources(
        _ movie: Movie,
        scope: CatalogScope,
        restriction: ContentRestriction = ContentRestriction(),
        isPremium: Bool = true,
        languages: [String] = [],
        in context: ModelContext
    ) -> [VODSourceOption] {
        VODSourceResolver.sources(
            for: movie,
            scope: scope,
            restriction: restriction,
            isPremium: isPremium,
            in: context,
            preferredLanguages: languages
        )
    }

    // MARK: Resolver

    @Test func `movie sources list every copy of the title, the current one included, by playlist priority`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeMovie(playlistA, 1, tmdbId: 42, in: context)
        let sameList = makeMovie(playlistA, 2, tmdbId: 42, in: context)
        let otherList = makeMovie(playlistB, 3, tmdbId: 42, in: context)
        _ = makeMovie(playlistB, 4, tmdbId: 7, in: context)
        try context.save()

        let sources = movieSources(current, scope: combined(playlistB, playlistA), in: context)
        #expect(sources.map(\.rowID) == [otherList.id, current.id, sameList.id])
        #expect(sources.map(\.playlistName) == ["Provider B", "Provider A", "Provider A"])
        #expect(sources.map(\.playlistID) == [playlistB.id, playlistA.id, playlistA.id])
    }

    @Test func `series sources carry the owning playlist's name`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeSeries(playlistA, 1, tmdbId: 314, in: context)
        let otherList = makeSeries(playlistB, 2, tmdbId: 314, in: context)
        try context.save()

        let sources = VODSourceResolver.sources(
            for: current,
            scope: combined(playlistA, playlistB),
            isPremium: true,
            in: context,
            preferredLanguages: []
        )
        #expect(sources.map(\.rowID) == [current.id, otherList.id])
        #expect(sources.map(\.playlistName) == ["Provider A", "Provider B"])
    }

    @Test func `copies on playlists outside the scope are left out`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeMovie(playlistA, 1, tmdbId: 42, in: context)
        let sameList = makeMovie(playlistA, 2, tmdbId: 42, in: context)
        _ = makeMovie(playlistB, 3, tmdbId: 42, in: context)
        try context.save()

        let sources = movieSources(current, scope: .isolated(playlistA.id), in: context)
        #expect(sources.map(\.rowID) == [current.id, sameList.id])
    }

    @Test func `copies with no owning playlist are dropped`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider A", in: context)

        let current = makeMovie(playlist, 1, tmdbId: 42, in: context)
        let orphan = Movie(id: "\(UUID().uuidString)-movie-2", streamId: 2, name: "Movie 2")
        orphan.tmdbId = 42
        context.insert(orphan)
        try context.save()

        let sources = movieSources(current, scope: .isolated(playlist.id), in: context)
        #expect(sources.map(\.rowID) == [current.id])
    }

    @Test func `without Pro copies on locked playlists are hidden, the free playlist's kept`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let free = makePlaylist(name: "Provider A", addedAt: 1_700_000_000, in: context)
        let locked = makePlaylist(name: "Provider B", addedAt: 1_700_000_001, in: context)

        let current = makeMovie(free, 1, tmdbId: 42, in: context)
        let sameList = makeMovie(free, 2, tmdbId: 42, in: context)
        _ = makeMovie(locked, 3, tmdbId: 42, in: context)
        try context.save()

        let sources = movieSources(current, scope: combined(free, locked), isPremium: false, in: context)
        #expect(sources.map(\.rowID) == [current.id, sameList.id])
    }

    @Test func `copies in a hidden or restricted category are hidden`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeMovie(playlistA, 1, tmdbId: 42, categoryId: "a-vod-1", in: context)
        _ = makeMovie(playlistB, 2, tmdbId: 42, categoryId: "b-vod-adult", in: context)
        let visible = makeMovie(playlistB, 3, tmdbId: 42, categoryId: "b-vod-2", in: context)
        try context.save()

        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["b-vod-adult"])
        let sources = movieSources(current, scope: combined(playlistA, playlistB), restriction: restriction, in: context)
        #expect(sources.map(\.rowID) == [current.id, visible.id])
    }

    @Test func `without a tmdb id copies group by title key`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)

        let current = makeMovie(playlistA, 1, name: "DE | Der Pate (1972)", tmdbId: nil, in: context)
        let copy = makeMovie(playlistB, 2, name: "Der Pate (1972) 4K", tmdbId: nil, in: context)
        _ = makeMovie(playlistB, 3, name: "Der Pate II (1974)", tmdbId: nil, in: context)
        try context.save()

        let sources = movieSources(current, scope: combined(playlistA, playlistB), in: context)
        #expect(sources.map(\.rowID) == [current.id, copy.id])
    }

    @Test func `a row with no tmdb id and no key is its only source`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider A", in: context)

        let current = makeMovie(playlist, 1, name: "4K", tmdbId: nil, in: context)
        current.titleGroupKey = nil
        try context.save()

        #expect(movieSources(current, scope: .isolated(playlist.id), in: context).map(\.rowID) == [current.id])
    }

    @Test func `within a playlist the preferred language leads, then quality`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider A", in: context)

        let englishUHD = makeMovie(playlist, 1, name: "EN | Heat (1995) 4K", tmdbId: 949, in: context)
        let germanHD = makeMovie(playlist, 2, name: "DE | Heat (1995) HD", tmdbId: 949, in: context)
        let germanFHD = makeMovie(playlist, 3, name: "DE | Heat (1995) FHD", tmdbId: 949, in: context)
        try context.save()

        let sources = movieSources(englishUHD, scope: .isolated(playlist.id), languages: ["de"], in: context)
        #expect(sources.map(\.rowID) == [germanFHD.id, germanHD.id, englishUHD.id])
    }

    @Test func `options carry the playlist's title, its parsed tags and the category's language`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider A", in: context)
        let category = Lume.Category(apiId: "1", name: "German Movies", parentId: 0, type: .vod, playlist: playlist)
        context.insert(category)

        let movie = makeMovie(playlist, 1, name: "Heat (1995) 4K HDR DV", tmdbId: 949, categoryId: category.id, in: context)
        try context.save()

        let option = try #require(movieSources(movie, scope: .isolated(playlist.id), in: context).first)
        #expect(option.title == "Heat (1995) 4K HDR DV")
        #expect(option.qualityLabel == "4K")
        #expect(option.isHDR)
        #expect(option.isDolbyVision)
        #expect(option.languageCode == "de")
        #expect(option.categoryName == "German Movies")
        #expect(!option.isMediaServer)
    }

    @Test func `media server rows are marked as one entry each`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let iptv = makePlaylist(name: "Provider A", in: context)
        let jellyfin = makePlaylist(name: "Jellyfin", in: context)
        jellyfin.sourceTypeRaw = PlaylistSourceType.jellyfin.rawValue

        let current = makeMovie(iptv, 1, tmdbId: 42, in: context)
        let server = makeMovie(jellyfin, 2, tmdbId: 42, in: context)
        try context.save()

        let sources = movieSources(current, scope: combined(iptv, jellyfin), in: context)
        #expect(sources.map(\.rowID) == [current.id, server.id])
        #expect(sources.map(\.isMediaServer) == [false, true])
    }

    // MARK: Decision

    private func option(_ id: String) -> VODSourceOption {
        VODSourceOption(
            rowID: id,
            playlistID: UUID(),
            playlistName: "P",
            title: id,
            qualityLabel: nil,
            isHDR: false,
            isDolbyVision: false,
            languageCode: nil,
            categoryName: nil,
            isMediaServer: false
        )
    }

    @Test func `no options decide nothing`() {
        #expect(VODSourceDecision.decide(options: [], remembered: nil, chooseBeforePlaying: true, forcePicker: true) == nil)
    }

    @Test func `a single source plays directly unless forced`() {
        let only = option("a")
        #expect(VODSourceDecision.decide(options: [only], remembered: nil, chooseBeforePlaying: true, forcePicker: false) == .play(only))
        #expect(
            VODSourceDecision.decide(options: [only], remembered: "a", chooseBeforePlaying: false, forcePicker: true)
                == .showPicker(preselected: only)
        )
    }

    @Test func `several sources ask with the remembered one preselected when choosing before playing`() {
        let best = option("a"), remembered = option("b")
        #expect(
            VODSourceDecision.decide(options: [best, remembered], remembered: "b", chooseBeforePlaying: true, forcePicker: false)
                == .showPicker(preselected: remembered)
        )
        #expect(
            VODSourceDecision.decide(options: [best, remembered], remembered: nil, chooseBeforePlaying: true, forcePicker: false)
                == .showPicker(preselected: best)
        )
    }

    @Test func `with the setting off the remembered source plays, else the best`() {
        let best = option("a"), remembered = option("b")
        #expect(
            VODSourceDecision.decide(options: [best, remembered], remembered: "b", chooseBeforePlaying: false, forcePicker: false)
                == .play(remembered)
        )
        #expect(
            VODSourceDecision.decide(options: [best, remembered], remembered: "gone", chooseBeforePlaying: false, forcePicker: false)
                == .play(best)
        )
    }

    @Test func `a failed source brings the picker back with another one preselected`() {
        let best = option("a"), remembered = option("b")
        #expect(
            VODSourceDecision.decide(
                options: [best, remembered], remembered: "b", chooseBeforePlaying: false, forcePicker: false, failed: ["b"]
            ) == .showPicker(preselected: best)
        )
        #expect(
            VODSourceDecision.decide(options: [best], remembered: nil, chooseBeforePlaying: false, forcePicker: false, failed: ["a"])
                == .showPicker(preselected: nil)
        )
    }

    // MARK: Preferences

    private func makeDefaults() throws -> UserDefaults {
        let suite = "VODSourceResolverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func `the pick is remembered per kind and group key`() throws {
        let defaults = try makeDefaults()
        VODSourcePreferences.remember(rowID: "row-1", .movie, groupKey: "tmdb:42", defaults: defaults)

        #expect(VODSourcePreferences.rememberedRowID(.movie, groupKey: "tmdb:42", among: [], defaults: defaults) == "row-1")
        #expect(VODSourcePreferences.rememberedRowID(.series, groupKey: "tmdb:42", among: [], defaults: defaults) == nil)

        VODSourcePreferences.remember(rowID: "row-2", .movie, groupKey: "tmdb:42", defaults: defaults)
        #expect(VODSourcePreferences.rememberedRowID(.movie, groupKey: "tmdb:42", among: [], defaults: defaults) == "row-2")
    }

    @Test func `the oldest picks are evicted past capacity`() throws {
        let defaults = try makeDefaults()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0 ... VODSourcePreferences.capacity {
            VODSourcePreferences.remember(
                rowID: "row-\(index)", .movie, groupKey: "t:\(index)|", at: start.addingTimeInterval(Double(index)), defaults: defaults
            )
        }
        #expect(VODSourcePreferences.rememberedRowID(.movie, groupKey: "t:0|", among: [], defaults: defaults) == nil)
        #expect(VODSourcePreferences.rememberedRowID(.movie, groupKey: "t:1|", among: [], defaults: defaults) == "row-1")
    }

    @Test func `a pick survives the title's key moving to its TMDB id`() throws {
        let defaults = try makeDefaults()
        VODSourcePreferences.remember(rowID: "row-2", .movie, groupKey: "t:inception|2010", defaults: defaults)
        VODSourcePreferences.remember(rowID: "row-2", .series, groupKey: "t:other|2010", defaults: defaults)

        #expect(VODSourcePreferences.rememberedRowID(.movie, groupKey: "tmdb:27205", among: ["row-9"], defaults: defaults) == nil)
        #expect(
            VODSourcePreferences.rememberedRowID(.movie, groupKey: "tmdb:27205", among: ["row-1", "row-2"], defaults: defaults)
                == "row-2"
        )
        #expect(VODSourcePreferences.rememberedRowID(.movie, groupKey: "tmdb:27205", among: [], defaults: defaults) == "row-2")
        #expect(VODSourcePreferences.rememberedRowID(.movie, groupKey: "t:inception|2010", among: [], defaults: defaults) == nil)
        #expect(VODSourcePreferences.rememberedRowID(.series, groupKey: "t:other|2010", among: [], defaults: defaults) == "row-2")
    }

    @Test func `remembered picks stay out of the diagnostic export`() throws {
        let defaults = try makeDefaults()
        defaults.set("row-1", forKey: VODSourcePreferences.storageKey)
        #expect(!DebugLogExporter.settingsLines(defaults).contains { $0.hasPrefix(VODSourcePreferences.storageKey) })
    }
}
