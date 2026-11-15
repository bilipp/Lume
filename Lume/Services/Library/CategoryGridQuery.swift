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
        excludingSports: Set<String> = SportarrPlaybackRegistry.shared.browseHiddenIDs
    ) -> FetchDescriptor<Movie> {
        guard grouped else {
            return FetchDescriptor(predicate: #Predicate<Movie> { $0.categoryId == categoryId && !excludingSports.contains($0.id) }, sortBy: sortBy)
        }
        return FetchDescriptor(
            predicate: #Predicate<Movie> { $0.categoryId == categoryId && !excludingSports.contains($0.id) && $0.isCategoryGroupPrimary == true },
            sortBy: sortBy
        )
    }

    static func series(
        categoryId: String,
        grouped: Bool,
        sortBy: [SortDescriptor<Series>] = [],
        excludingSports: Set<String> = SportarrPlaybackRegistry.shared.browseHiddenIDs
    ) -> FetchDescriptor<Series> {
        guard grouped else {
            return FetchDescriptor(predicate: #Predicate<Series> { $0.categoryId == categoryId && !excludingSports.contains($0.id) }, sortBy: sortBy)
        }
        return FetchDescriptor(
            predicate: #Predicate<Series> { $0.categoryId == categoryId && !excludingSports.contains($0.id) && $0.isCategoryGroupPrimary == true },
            sortBy: sortBy
        )
    }
}
