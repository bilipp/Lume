import Foundation
@testable import Lume
import SwiftData
import Testing

struct MediaFavoritesTests {
    // MARK: - Favoriting

    @Test func `favorite stamps the flag and date and leaves the order unstamped`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-1", streamId: 1, name: "Target")
        context.insert(movie)
        try context.save()

        let favorited = MediaFavorites.toggle(movie, in: context)

        #expect(favorited)
        #expect(movie.isFavorite)
        #expect(movie.favoriteOrder == nil)
        let stamped = try #require(movie.addedToWatchlistDate)
        #expect(abs(stamped.timeIntervalSinceNow) < 5)
    }

    /// The reason a new favorite must NOT be stamped, asserted through the real
    /// comparator rather than through `favoriteOrder` alone.
    ///
    /// Both surfaces that render favorites sort on `favoriteOrder ?? Int.max`
    /// (`HomeView.favoriteItems` and `FavoriteManagementView.favorites`), so an
    /// unstamped favorite sorts last on its own. Stamping a next-highest slot
    /// would instead place it ahead of every favorite the user never reordered.
    @Test func `a new favorite sorts after the favorites already on screen`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)

        let handOrdered = Movie(id: "m-hand", streamId: 1, name: "Hand ordered")
        handOrdered.isFavorite = true
        handOrdered.favoriteOrder = 0
        context.insert(handOrdered)

        // The common case: favorited, never reordered, so still unstamped.
        let untouched = Series(id: "s-untouched", seriesId: 2, name: "Untouched")
        untouched.isFavorite = true
        context.insert(untouched)

        let movie = Movie(id: "m-new", streamId: 3, name: "New")
        context.insert(movie)
        try context.save()

        MediaFavorites.toggle(movie, in: context)

        // The production comparator, verbatim.
        let ordered: [any FavoriteOrderable] = [handOrdered, untouched, movie]
            .sorted { ($0.favoriteOrder ?? Int.max) < ($1.favoriteOrder ?? Int.max) }
        #expect(ordered.last?.id == movie.id)
        #expect(ordered.first?.id == handOrdered.id)
    }

    // MARK: - Unfavoriting

    /// All three fields have to clear: `ContentStateValues.isEmpty` requires
    /// `!isFavorite && addedToWatchlistDate == nil && favoriteOrder == nil`
    /// before `CloudSyncEngine` deletes the mirror record.
    @Test func `unfavorite clears flag date and order`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-1", streamId: 1, name: "Target")
        movie.isFavorite = true
        movie.addedToWatchlistDate = Date()
        movie.favoriteOrder = 4
        context.insert(movie)
        try context.save()

        let favorited = MediaFavorites.toggle(movie, in: context)

        #expect(!favorited)
        #expect(!movie.isFavorite)
        #expect(movie.addedToWatchlistDate == nil)
        #expect(movie.favoriteOrder == nil)
    }

    @Test func `unfavorite clears a series the same way`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let series = Series(id: "s-1", seriesId: 1, name: "Target")
        series.isFavorite = true
        series.addedToWatchlistDate = Date()
        series.favoriteOrder = 4
        context.insert(series)
        try context.save()

        MediaFavorites.toggle(series, in: context)

        #expect(!series.isFavorite)
        #expect(series.addedToWatchlistDate == nil)
        #expect(series.favoriteOrder == nil)
    }

    /// The favorites manager removes through the same primitive, so its removals
    /// clear the watchlist stamp too and stop leaving a mirror record behind.
    @Test func `clearing favorite state drops the watchlist stamp as well`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-1", streamId: 1, name: "Movie")
        movie.isFavorite = true
        movie.addedToWatchlistDate = Date()
        movie.favoriteOrder = 2
        context.insert(movie)
        let series = Series(id: "s-1", seriesId: 1, name: "Series")
        series.isFavorite = true
        series.addedToWatchlistDate = Date()
        series.favoriteOrder = 3
        context.insert(series)
        try context.save()

        MediaFavorites.clearFavoriteState(movie)
        MediaFavorites.clearFavoriteState(series)

        #expect(!movie.isFavorite)
        #expect(movie.favoriteOrder == nil)
        #expect(movie.addedToWatchlistDate == nil)
        #expect(!series.isFavorite)
        #expect(series.favoriteOrder == nil)
        #expect(series.addedToWatchlistDate == nil)
    }

    // MARK: - Parity between movie and series

    @Test func `series favorite matches movie favorite`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "m-1", streamId: 1, name: "Movie")
        let series = Series(id: "s-1", seriesId: 1, name: "Series")
        context.insert(movie)
        context.insert(series)
        try context.save()

        #expect(MediaFavorites.toggle(movie, in: context))
        #expect(MediaFavorites.toggle(series, in: context))

        #expect(movie.isFavorite == series.isFavorite)
        #expect((movie.addedToWatchlistDate != nil) == (series.addedToWatchlistDate != nil))
        #expect(movie.favoriteOrder == nil)
        #expect(series.favoriteOrder == nil)
    }

    // MARK: - Episodes

    @Test func `episode routes to its parent series`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let series = Series(id: "s-1", seriesId: 1, name: "Parent")
        context.insert(series)
        let episode = Episode(
            id: "e-1", episodeId: "1", title: "Ep 1",
            containerExtension: "mp4", seasonNum: 1, episodeNum: 1, series: series
        )
        context.insert(episode)
        try context.save()

        let favorited = MediaFavorites.toggle(episode, in: context)

        #expect(favorited)
        #expect(series.isFavorite)
        #expect(series.addedToWatchlistDate != nil)
        #expect(series.favoriteOrder == nil)
    }

    @Test func `episode without a parent series is a no op`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let episode = Episode(
            id: "e-orphan", episodeId: "1", title: "Ep 1",
            containerExtension: "mp4", seasonNum: 1, episodeNum: 1
        )
        context.insert(episode)
        try context.save()

        #expect(!MediaFavorites.toggle(episode, in: context))
        #expect(episode.series == nil)
    }

    // MARK: - Round trip

    /// A re-favorite must not inherit the slot it held before, which would
    /// silently jump the user's hand-ordering.
    @Test func `re favorite does not inherit its old order`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)

        let movie = Movie(id: "m-1", streamId: 1, name: "Target")
        movie.isFavorite = true
        movie.favoriteOrder = 3
        context.insert(movie)
        try context.save()

        MediaFavorites.toggle(movie, in: context)
        #expect(!movie.isFavorite)
        #expect(movie.favoriteOrder == nil)

        MediaFavorites.toggle(movie, in: context)

        #expect(movie.isFavorite)
        #expect(movie.favoriteOrder == nil)
        #expect(movie.addedToWatchlistDate != nil)
    }
}

// MARK: - Menu literals

/// Locks the wording of the context-menu items. The menu reuses literals that
/// are already translated in all eight non-source locales; any rename or
/// recapitalization creates a brand-new key with eight empty locales, which
/// `Scripts/check-translations.swift` rejects. Runtime resolution alone can't
/// catch that — an English key resolves to itself whether or not the catalog
/// knows it — so the catalog is asserted directly.
struct MediaFavoriteMenuStringsTests {
    private static let menuKeys = [
        "Add to Favorites",
        "Remove from Favorites",
        "Remove from Recently Watched",
        "More Like This",
        "Not Interested"
    ]

    @Test func `menu literals resolve to a non empty string`() {
        for key in Self.menuKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    @Test func `menu literals are translated in every locale`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.menuKeys {
            let localizations = try #require(catalog.localizations(for: key), "\(key) is not in the catalog")
            #expect(!localizations.isEmpty, "\(key) has no translations")
            for (language, value) in localizations {
                #expect(!value.isEmpty, "\(key) is untranslated in \(language)")
            }
        }
    }
}
