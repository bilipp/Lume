//
//  TitleGroupDetailSources.swift
//  Lume
//
//  The source logic a grouped movie or series detail screen shares across
//  platforms: which copy plays or shows, resume, and state across every copy.
//  Each screen keeps only its own picker presentation and switcher UI.
//

import SwiftData
import SwiftUI

protocol TitleGroupMovieDetail: View {
    var movie: Movie { get }
    var modelContext: ModelContext { get }
    var catalogScope: CatalogScope { get }
    var contentRestriction: ContentRestriction { get }
    var playlists: [Playlist] { get }
    var moviePlaylist: Playlist? { get }
    var groupStates: [String: TitleGroupState] { get nonmutating set }
    var sourceOptions: [VODSourceOption] { get nonmutating set }
    var failedSourceIDs: Set<String> { get nonmutating set }
    var sourcePicker: ContentSourcePickerRequest? { get nonmutating set }
    var pendingMedia: PlayableMedia? { get nonmutating set }
    var playingMedia: PlayableMedia? { get nonmutating set }
    #if os(macOS)
        var openWindow: OpenWindowAction {
            get
        }
    #endif
    #if !os(tvOS)
        var downloads: DownloadManager {
            get
        }
    #endif
}

/// What a resolved source list depends on besides the title itself.
struct VODSourcesKey: Equatable {
    let scope: CatalogScope
    let restriction: ContentRestriction
    let isPremium: Bool
    let playlistIDs: [UUID]
}

extension TitleGroupMovieDetail {
    var sourcesKey: VODSourcesKey {
        VODSourcesKey(
            scope: catalogScope,
            restriction: contentRestriction,
            isPremium: PremiumManager.isPremium(nil),
            playlistIDs: playlists.map(\.id)
        )
    }

    var groupState: TitleGroupState {
        TitleGroupStateLookup.state(of: movie, in: groupStates)
    }

    func resolveSources() {
        sourceOptions = VODSourceResolver.sources(
            for: movie,
            scope: catalogScope,
            restriction: contentRestriction,
            isPremium: PremiumManager.isPremium(nil),
            playlists: playlists,
            in: modelContext
        )
    }

    func refreshGroupState() {
        guard let key = movie.titleGroupKey else {
            groupStates = [:]
            return
        }
        groupStates = TitleGroupStateLookup.movies(keys: [key], in: modelContext)
    }

    // MARK: - Actions

    /// Resume reopens the copy last watched as it is; Play goes through the
    /// title's sources and the picker's skip rules. `forcePicker` (long press)
    /// always asks.
    func startPlayback(forcePicker: Bool = false) {
        if !forcePicker, let lastRow = resumeRow, let playlist = playlists.owner(ofContentID: lastRow.id) {
            present(PlayableMedia.from(movie: lastRow, playlist: playlist), from: lastRow.id, afterSheet: false)
            return
        }
        if sourceOptions.isEmpty { resolveSources() }
        let (decision, remembered) = VODSourceDecision.decide(
            .movie, groupKey: groupKey, options: sourceOptions, forcePicker: forcePicker, failed: failedSourceIDs
        )
        switch decision {
        case let .play(option):
            play(option, afterSheet: false)
        case let .showPicker(preselected):
            showSourcePicker(preselected: preselected, remembered: remembered)
        case nil:
            guard let playlist = moviePlaylist else { return }
            present(PlayableMedia.from(movie: movie, playlist: playlist), from: movie.id, afterSheet: false)
        }
    }

    private var groupKey: String {
        VODSourcePreferences.groupKey(of: movie)
    }

    private func showSourcePicker(preselected: VODSourceOption?, remembered: String?) {
        sourcePicker = ContentSourcePickerRequest(
            title: movie.name,
            kind: .movie,
            groupKey: groupKey,
            options: sourceOptions,
            preselectedID: preselected?.rowID,
            rememberedID: remembered,
            failedIDs: failedSourceIDs
        )
    }

    /// A copy this screen played failed on every engine: the picker comes
    /// back with it marked, and nothing else is tried on its own.
    func takeSourceFailure() {
        guard let failure = VODSourceFailureHandoff.shared.take(ifAmong: sourceOptions.map(\.rowID)) else { return }
        failedSourceIDs.insert(failure.sourceRowID)
        let (decision, remembered) = VODSourceDecision.decide(
            .movie, groupKey: groupKey, options: sourceOptions, forcePicker: false, failed: failedSourceIDs
        )
        if case let .showPicker(preselected) = decision {
            showSourcePicker(preselected: preselected, remembered: remembered)
        }
    }

    /// The copy the title was last watched on, while it can still be played
    /// here: its playlist installed and unlocked, its category not restricted.
    private var resumeRow: Movie? {
        guard let last = groupState.lastWatched, last.watchProgress > 1,
              !failedSourceIDs.contains(last.rowID),
              let lastRow = row(withID: last.rowID),
              playlists.owner(ofContentID: lastRow.id) != nil,
              !playlists.isLocked(contentID: lastRow.id),
              !contentRestriction.hides(categoryID: lastRow.categoryId)
        else { return nil }
        return lastRow
    }

    private func row(withID id: String) -> Movie? {
        id == movie.id ? movie : Movie.row(id: id, in: modelContext)
    }

    /// Plays `option` through the playlist that owns its row, never the active one.
    func play(_ option: VODSourceOption, afterSheet: Bool = true) {
        guard let picked = row(withID: option.rowID),
              let playlist = playlists.first(where: { $0.id == option.playlistID })
        else { return }
        failedSourceIDs.remove(option.rowID)
        present(PlayableMedia.from(movie: picked, playlist: playlist), from: picked.id, afterSheet: afterSheet)
    }

    /// A cover presented while the source sheet is still animating out is torn
    /// down and presented again by UIKit (two stream opens), so a pick made
    /// there waits for the sheet's `onDismiss`.
    private func present(_ media: PlayableMedia?, from rowID: String, afterSheet: Bool) {
        guard let media else { return }
        if ExternalPlayback.open(media) { return }
        if sourceOptions.count > 1, sourceOptions.contains(where: { $0.rowID == rowID }) {
            VODSourceFailureHandoff.shared.expect(mediaID: media.id, sourceRowID: rowID)
        }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #else
            if afterSheet {
                pendingMedia = media
            } else {
                playingMedia = media
            }
        #endif
    }

    /// On writes only this row; off clears every copy, or the title would
    /// still show as a favorite through another one.
    func toggleFavorite() {
        TitleGroupFavorites.toggle(movie, showsFavorite: groupState.isFavorite, in: modelContext)
        refreshGroupState()
    }

    func toggleWatched() {
        if groupState.isWatched {
            TitleGroupSiblings.markUnwatched(movie, in: modelContext)
            try? modelContext.save()
            WatchedTrackers.sync(movie: movie, watched: false)
        } else {
            movie.isWatched = true
            movie.watchProgress = Double(movie.durationSecs ?? 0)
            #if !os(tvOS)
                downloads.checkAutoDelete(id: movie.id)
            #endif
            WatchedTrackers.sync(movie: movie, watched: true)
        }
        refreshGroupState()
    }
}

protocol TitleGroupSeriesDetail: View {
    var series: Series { get }
    var modelContext: ModelContext { get }
    var catalogScope: CatalogScope { get }
    var contentRestriction: ContentRestriction { get }
    var playlists: [Playlist] { get }
    var seriesPlaylist: Playlist? { get }
    var nextEpisode: Episode? { get }
    var activeSeries: Series? { get nonmutating set }
    var selectedSeason: Int { get nonmutating set }
    var groupStates: [String: TitleGroupState] { get nonmutating set }
    var sourceOptions: [VODSourceOption] { get nonmutating set }
    var failedSourceIDs: Set<String> { get nonmutating set }
    var sourcePicker: ContentSourcePickerRequest? { get nonmutating set }
    var playingMedia: PlayableMedia? { get nonmutating set }
    #if os(macOS)
        var openWindow: OpenWindowAction {
            get
        }
    #endif
    func recomputeSeasons()
    func determineDefaultSeason() -> Int
    func loadEpisodesIfNeeded() async
}

extension TitleGroupSeriesDetail {
    var sourcesKey: VODSourcesKey {
        VODSourcesKey(
            scope: catalogScope,
            restriction: contentRestriction,
            isPremium: PremiumManager.isPremium(nil),
            playlistIDs: playlists.map(\.id)
        )
    }

    /// The copy on screen: the picked one once sources are resolved, else the
    /// row the screen was opened with.
    var shown: Series {
        activeSeries ?? series
    }

    var groupState: TitleGroupState {
        TitleGroupStateLookup.state(of: shown, in: groupStates)
    }

    var groupKey: String {
        VODSourcePreferences.groupKey(of: series)
    }

    var currentSourceLabel: String {
        sourceOptions.first { $0.rowID == shown.id }?.summaryLabel ?? ""
    }

    func resolveSources() {
        sourceOptions = VODSourceResolver.sources(
            for: series,
            scope: catalogScope,
            restriction: contentRestriction,
            isPremium: PremiumManager.isPremium(nil),
            playlists: playlists,
            in: modelContext
        )
    }

    func refreshGroupState() {
        guard let key = series.titleGroupKey else {
            groupStates = [:]
            return
        }
        groupStates = TitleGroupStateLookup.series(keys: [key], in: modelContext)
    }

    /// The copy picked last on this device, else the one last watched (so
    /// Resume continues where the viewer left off), else the best-ranked one.
    func initialSource() -> Series {
        let candidates = [
            VODSourcePreferences.rememberedRowID(.series, groupKey: groupKey, among: sourceOptions.map(\.rowID)),
            groupState.lastWatched?.rowID,
            sourceOptions.first?.rowID
        ]
        for id in candidates.compactMap(\.self) where sourceOptions.contains(where: { $0.rowID == id }) {
            if let row = row(withID: id) { return row }
        }
        return series
    }

    func row(withID id: String) -> Series? {
        if id == series.id { return series }
        if let activeSeries, id == activeSeries.id { return activeSeries }
        return Series.row(id: id, in: modelContext)
    }

    func show(_ row: Series) {
        guard row.id != shown.id else { return }
        activeSeries = row
        recomputeSeasons()
        selectedSeason = determineDefaultSeason()
    }

    /// The copy on screen is the one last watched, or its next episode is
    /// part-way through, and it can still be played here.
    var isResuming: Bool {
        let started = shown.id == groupState.lastWatched?.rowID || (nextEpisode?.watchProgress ?? 0) > 1
        return started && seriesPlaylist != nil && !playlists.isLocked(contentID: shown.id)
            && !failedSourceIDs.contains(shown.id)
    }

    /// Resume plays the next episode of the copy last watched as it is; Play
    /// goes through the title's sources and the picker's skip rules.
    /// `forcePicker` (long press) always asks.
    func playNext(forcePicker: Bool = false) {
        if !forcePicker, isResuming, let episode = nextEpisode {
            playEpisode(episode)
            return
        }
        if sourceOptions.isEmpty { resolveSources() }
        let (decision, remembered) = VODSourceDecision.decide(
            .series, groupKey: groupKey, options: sourceOptions, forcePicker: forcePicker, failed: failedSourceIDs
        )
        switch decision {
        case let .play(option):
            Task { await play(option) }
        case let .showPicker(preselected):
            showSourcePicker(preselected: preselected, remembered: remembered)
        case nil:
            if let episode = nextEpisode { playEpisode(episode) }
        }
    }

    func showSourcePicker(preselected: VODSourceOption?, remembered: String?) {
        sourcePicker = ContentSourcePickerRequest(
            title: series.name,
            kind: .series,
            groupKey: groupKey,
            options: sourceOptions,
            preselectedID: preselected?.rowID,
            rememberedID: remembered,
            failedIDs: failedSourceIDs
        )
    }

    /// A copy this screen played failed on every engine: the picker comes
    /// back with it marked, and nothing else is tried on its own.
    func takeSourceFailure() {
        guard let failure = VODSourceFailureHandoff.shared.take(ifAmong: sourceOptions.map(\.rowID)) else { return }
        failedSourceIDs.insert(failure.sourceRowID)
        let (decision, remembered) = VODSourceDecision.decide(
            .series, groupKey: groupKey, options: sourceOptions, forcePicker: false, failed: failedSourceIDs
        )
        if case let .showPicker(preselected) = decision {
            showSourcePicker(preselected: preselected, remembered: remembered)
        }
    }

    /// Switches to `option`'s copy, loading its episodes if needed, and plays
    /// its next episode.
    func play(_ option: VODSourceOption) async {
        guard let row = row(withID: option.rowID) else { return }
        failedSourceIDs.remove(option.rowID)
        show(row)
        await loadEpisodesIfNeeded()
        guard shown.id == row.id, let episode = nextEpisode else { return }
        playEpisode(episode)
    }

    /// Plays an episode of the copy on screen through the playlist that owns it.
    func playEpisode(_ episode: Episode) {
        guard let playlist = seriesPlaylist,
              let media = PlayableMedia.from(episode: episode, playlist: playlist) else { return }
        if sourceOptions.count > 1 {
            VODSourcePreferences.remember(rowID: shown.id, .series, groupKey: groupKey)
        }
        if ExternalPlayback.open(media) { return }
        if sourceOptions.count > 1, sourceOptions.contains(where: { $0.rowID == shown.id }) {
            VODSourceFailureHandoff.shared.expect(mediaID: media.id, sourceRowID: shown.id)
        }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #else
            playingMedia = media
        #endif
    }

    /// On writes only the copy on screen; off clears every copy, or the title
    /// would still show as a favorite through another one.
    func toggleFavorite() {
        TitleGroupFavorites.toggle(shown, showsFavorite: groupState.isFavorite, in: modelContext)
        refreshGroupState()
    }
}
