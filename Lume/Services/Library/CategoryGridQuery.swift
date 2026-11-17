//
//  CategoryGridQuery.swift
//  Lume
//
//  The fetch behind a movie or series category grid. With grouping on it lists
//  only each title's category primary, filtered in SQL so paging stays exact.
//

import Foundation
import SwiftData

nonisolated enum CategoryGridQuery {
    static func movies(
        categoryId: String,
        grouped: Bool,
        sortBy: [SortDescriptor<Movie>] = [],
        routesSports: Bool = false
    ) -> FetchDescriptor<Movie> {
        guard grouped else {
            return FetchDescriptor(predicate: ordinary(#Predicate<Movie> { $0.categoryId == categoryId }, routesSports), sortBy: sortBy)
        }
        return FetchDescriptor(
            predicate: ordinary(#Predicate<Movie> { $0.categoryId == categoryId && $0.isCategoryGroupPrimary == true }, routesSports),
            sortBy: sortBy
        )
    }

    static func series(
        categoryId: String,
        grouped: Bool,
        sortBy: [SortDescriptor<Series>] = [],
        routesSports: Bool = false
    ) -> FetchDescriptor<Series> {
        guard grouped else {
            return FetchDescriptor(predicate: ordinary(#Predicate<Series> { $0.categoryId == categoryId }, routesSports), sortBy: sortBy)
        }
        return FetchDescriptor(
            predicate: ordinary(#Predicate<Series> { $0.categoryId == categoryId && $0.isCategoryGroupPrimary == true }, routesSports),
            sortBy: sortBy
        )
    }

    /// With Sportarr integration on, an item its source identified as sports
    /// is browsed under Sports → Replays and leaves ordinary discovery: the
    /// category grids, Recently Added and the genre pages all compose through
    /// here. Off, the predicate is returned untouched, so an ordinary query is
    /// exactly the one it always was. Search, Favorites and Continue Watching
    /// never route.
    static func ordinary(_ base: Predicate<Movie>, _ routesSports: Bool) -> Predicate<Movie> {
        guard routesSports else { return base }
        return #Predicate { base.evaluate($0) && $0.sportsRef == nil }
    }

    /// A league stays here until its games are loaded: a series listed as a
    /// shell has nothing in Replays yet, and hiding it would strand it.
    static func ordinary(_ base: Predicate<Series>, _ routesSports: Bool) -> Predicate<Series> {
        guard routesSports else { return base }
        return #Predicate { base.evaluate($0) && ($0.sportsRef == nil || $0.episodes.isEmpty) }
    }
}
