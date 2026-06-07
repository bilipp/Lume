import Foundation
@testable import Lume
import SwiftUI
import Testing

struct SortOptionTests {
    // MARK: - CategorySortOption

    @Test func `category sort playlist order`() {
        let cats = makeUnsortedCategories()
        let sorted = CategorySortOption.playlist.sort(cats)
        #expect(sorted.count == 4)
        #expect(sorted[0].name == "B Category")
        #expect(sorted[1].name == "A Category")
        #expect(sorted[2].name == "D Category")
        #expect(sorted[3].name == "C Category")
    }

    @Test func `category sort name ascending`() {
        let cats = makeUnsortedCategories()
        let sorted = CategorySortOption.nameAscending.sort(cats)
        #expect(sorted[0].name == "A Category")
        #expect(sorted[1].name == "B Category")
        #expect(sorted[2].name == "C Category")
        #expect(sorted[3].name == "D Category")
    }

    @Test func `category sort name descending`() {
        let cats = makeUnsortedCategories()
        let sorted = CategorySortOption.nameDescending.sort(cats)
        #expect(sorted[0].name == "D Category")
        #expect(sorted[3].name == "A Category")
    }

    @Test func `category sort empty array`() {
        let sorted = CategorySortOption.playlist.sort([])
        #expect(sorted.isEmpty)
    }

    @Test func `category sort preserves duplicate names`() {
        let dupes = makeDuplicateNameCategories()
        let sorted = CategorySortOption.nameAscending.sort(dupes)
        #expect(sorted.count == 3)
        #expect(sorted[0].sortOrder < sorted[1].sortOrder || sorted[0].sortOrder == sorted[1].sortOrder)
    }

    // MARK: - ContentSortOption - Movie Descriptors

    @Test func `movie sort playlist order`() {
        let movies = makeUnsortedMovies()
        let sorted = movies.sorted(using: ContentSortOption.playlist.movieDescriptors)
        #expect(sorted[0].streamId == 2) // num=1
        #expect(sorted[1].streamId == 1) // num=2
        #expect(sorted[2].streamId == 3) // num=3
    }

    @Test func `movie sort name ascending`() {
        let movies = makeUnsortedMovies()
        let sorted = movies.sorted(using: ContentSortOption.nameAscending.movieDescriptors)
        #expect(sorted[0].name == "Alpha")
        #expect(sorted[1].name == "Beta")
        #expect(sorted[2].name == "Gamma")
    }

    @Test func `movie sort name descending`() {
        let movies = makeUnsortedMovies()
        let sorted = movies.sorted(using: ContentSortOption.nameDescending.movieDescriptors)
        #expect(sorted[0].name == "Gamma")
        #expect(sorted[2].name == "Alpha")
    }

    @Test func `movie sort newest first`() {
        let movies = makeUnsortedMovies()
        let sorted = movies.sorted(using: ContentSortOption.newest.movieDescriptors)
        #expect(sorted[0].added == "200")
        #expect(sorted[1].added == "100")
        #expect(sorted[2].added == "50")
    }

    @Test func `movie sort oldest first`() {
        let movies = makeUnsortedMovies()
        let sorted = movies.sorted(using: ContentSortOption.oldest.movieDescriptors)
        #expect(sorted[0].added == "50")
        #expect(sorted[2].added == "200")
    }

    // MARK: - ContentSortOption - Series Descriptors

    @Test func `series sort playlist order`() {
        let series = makeUnsortedSeries()
        let sorted = series.sorted(using: ContentSortOption.playlist.seriesDescriptors)
        #expect(sorted[0].name == "First") // num=0
        #expect(sorted[1].name == "Alpha Series") // num=1, name before "Second"
    }

    @Test func `series sort name ascending`() {
        let series = makeUnsortedSeries()
        let sorted = series.sorted(using: ContentSortOption.nameAscending.seriesDescriptors)
        #expect(sorted[0].name == "Alpha Series")
        #expect(sorted[1].name == "Beta Series")
    }

    @Test func `series sort newest first`() {
        let series = makeUnsortedSeries()
        let sorted = series.sorted(using: ContentSortOption.newest.seriesDescriptors)
        #expect(sorted[0].lastModified == "300")
        #expect(sorted[1].lastModified == "200")
    }

    @Test func `series sort oldest first`() {
        let series = makeUnsortedSeries()
        let sorted = series.sorted(using: ContentSortOption.oldest.seriesDescriptors)
        #expect(sorted[0].lastModified == "100")
        #expect(sorted[1].lastModified == "200")
    }

    @Test func `live stream sort name ascending`() {
        let streams = makeUnsortedStreams()
        let sorted = streams.sorted(using: ContentSortOption.nameAscending.liveStreamDescriptors)
        #expect(sorted[0].name == "A Channel")
        #expect(sorted[1].name == "Z Channel")
    }

    @Test func `live stream sort name descending`() {
        let streams = makeUnsortedStreams()
        let sorted = streams.sorted(using: ContentSortOption.nameDescending.liveStreamDescriptors)
        #expect(sorted[0].name == "Z Channel")
        #expect(sorted[1].name == "A Channel")
    }

    @Test func `live stream sort newest first`() {
        let streams = makeUnsortedStreams()
        let sorted = streams.sorted(using: ContentSortOption.newest.liveStreamDescriptors)
        #expect(sorted[0].added == "200")
        #expect(sorted[1].added == "100")
    }

    @Test func `live stream sort oldest first`() {
        let streams = makeUnsortedStreams()
        let sorted = streams.sorted(using: ContentSortOption.oldest.liveStreamDescriptors)
        #expect(sorted[0].added == "100")
        #expect(sorted[1].added == "200")
    }

    // MARK: - ContentSortOption - LiveStream Descriptors

    @Test func `live stream sort playlist order`() {
        let streams = makeUnsortedStreams()
        let sorted = streams.sorted(using: ContentSortOption.playlist.liveStreamDescriptors)
        #expect(sorted[0].name == "Z Channel")
        #expect(sorted[1].name == "A Channel")
    }

    // MARK: - Labels and Icons

    @Test func `category sort labels`() {
        #expect(CategorySortOption.playlist.label == "Playlist Order")
        #expect(CategorySortOption.nameAscending.label == "Name (A–Z)")
        #expect(CategorySortOption.nameDescending.label == "Name (Z–A)")
    }

    @Test func `content sort labels`() {
        #expect(ContentSortOption.playlist.label == "Playlist Order")
        #expect(ContentSortOption.nameAscending.label == "Name (A–Z)")
        #expect(ContentSortOption.nameDescending.label == "Name (Z–A)")
        #expect(ContentSortOption.newest.label == "Newest First")
        #expect(ContentSortOption.oldest.label == "Oldest First")
    }

    @Test func `category sort icons`() {
        #expect(CategorySortOption.playlist.icon == "list.number")
        #expect(CategorySortOption.nameAscending.icon == "textformat.abc")
    }

    // MARK: - SortStorageKeys

    @Test func `storage key constants`() {
        #expect(SortStorageKey.liveCategories == "lume.sort.live.categories")
        #expect(SortStorageKey.liveContent == "lume.sort.live.content")
        #expect(SortStorageKey.movieCategories == "lume.sort.movies.categories")
        #expect(SortStorageKey.movieContent == "lume.sort.movies.content")
        #expect(SortStorageKey.seriesCategories == "lume.sort.series.categories")
        #expect(SortStorageKey.seriesContent == "lume.sort.series.content")
    }

    // MARK: - Helpers

    private func makeUnsortedCategories() -> [Lume.Category] {
        let playlist = Playlist(name: "P", serverURL: "http://x.com", username: "u", password: "p")
        return [
            Lume.Category(apiId: "2", name: "B Category", parentId: 0, type: .vod, playlist: playlist),
            Lume.Category(apiId: "1", name: "A Category", parentId: 0, type: .vod, playlist: playlist),
            Lume.Category(apiId: "4", name: "D Category", parentId: 0, type: .vod, playlist: playlist),
            Lume.Category(apiId: "3", name: "C Category", parentId: 0, type: .vod, playlist: playlist)
        ].enumerated().map { idx, cat in cat.sortOrder = idx * 2; return cat }
    }

    private func makeDuplicateNameCategories() -> [Lume.Category] {
        let playlist = Playlist(name: "P", serverURL: "http://x.com", username: "u", password: "p")
        return [
            Lume.Category(apiId: "1", name: "Same Name", parentId: 0, type: .vod, playlist: playlist),
            Lume.Category(apiId: "2", name: "Same Name", parentId: 0, type: .vod, playlist: playlist),
            Lume.Category(apiId: "3", name: "Z Alone", parentId: 0, type: .vod, playlist: playlist)
        ].enumerated().map { idx, cat in cat.sortOrder = idx; return cat }
    }

    private func makeUnsortedMovies() -> [Movie] {
        [
            Movie(id: "m-1", streamId: 1, name: "Gamma", added: "50", num: 2),
            Movie(id: "m-2", streamId: 2, name: "Alpha", added: "100", num: 1),
            Movie(id: "m-3", streamId: 3, name: "Beta", added: "200", num: 3)
        ]
    }

    private func makeUnsortedSeries() -> [Series] {
        [
            Series(id: "s-1", seriesId: 2, name: "Beta Series", lastModified: "200", num: 2),
            Series(id: "s-2", seriesId: 1, name: "Alpha Series", lastModified: "100", num: 1),
            Series(id: "s-3", seriesId: 3, name: "Second", lastModified: "300", num: 1),
            Series(id: "s-4", seriesId: 4, name: "First", lastModified: "200", num: 0)
        ]
    }

    private func makeUnsortedStreams() -> [LiveStream] {
        [
            LiveStream(id: "l-1", streamId: 2, name: "A Channel", added: "100", num: 2),
            LiveStream(id: "l-2", streamId: 1, name: "Z Channel", added: "200", num: 1)
        ]
    }
}
