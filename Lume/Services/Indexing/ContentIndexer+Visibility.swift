//
//  ContentIndexer+Visibility.swift
//  Lume
//
//  Hidden-category filtering for the content index. Titles in hidden
//  categories are never indexed (no TMDB traffic, no embedding) and are
//  excluded from progress counts on both sides, so a pass still completes;
//  unhiding a category makes its titles pending again for the next pass.
//

import Foundation
import SwiftData

extension ContentIndexer {
    /// Ids of categories the user hid in Content Management. Read fresh on
    /// every chunk and every progress poll so a category hidden or unhidden
    /// mid-pass takes effect without waiting for the next kick.
    static func hiddenCategoryIDs(in context: ModelContext) throws -> Set<String> {
        let hidden = try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isHidden == true })
        )
        return Set(hidden.map(\.id))
    }

    /// The excluded ids as optionals, so a predicate can test the optional
    /// `categoryId` against them directly — the same `Set<String?>` shape the
    /// search predicates use, which is what survives SwiftData's SQL
    /// generation (`?? ""` and nil-check-plus-unwrap do not).
    private static func excludedOptional(_ excluded: Set<String>) -> (ids: Set<String?>, filters: Bool) {
        (Set(excluded.map(String?.some)), !excluded.isEmpty)
    }

    static func pendingMoviePredicate(excluding excluded: Set<String>) -> Predicate<Movie> {
        let (ids, filters) = excludedOptional(excluded)
        return #Predicate {
            $0.indexedAt == nil && (!filters || $0.categoryId == nil || !ids.contains($0.categoryId))
        }
    }

    static func pendingSeriesPredicate(excluding excluded: Set<String>) -> Predicate<Series> {
        let (ids, filters) = excludedOptional(excluded)
        return #Predicate {
            $0.indexedAt == nil && (!filters || $0.categoryId == nil || !ids.contains($0.categoryId))
        }
    }

    static func visibleMoviePredicate(excluding excluded: Set<String>) -> Predicate<Movie> {
        let (ids, filters) = excludedOptional(excluded)
        return #Predicate {
            !filters || $0.categoryId == nil || !ids.contains($0.categoryId)
        }
    }

    static func visibleSeriesPredicate(excluding excluded: Set<String>) -> Predicate<Series> {
        let (ids, filters) = excludedOptional(excluded)
        return #Predicate {
            !filters || $0.categoryId == nil || !ids.contains($0.categoryId)
        }
    }

    static func indexedMoviePredicate(excluding excluded: Set<String>) -> Predicate<Movie> {
        let (ids, filters) = excludedOptional(excluded)
        return #Predicate {
            $0.indexedAt != nil && (!filters || $0.categoryId == nil || !ids.contains($0.categoryId))
        }
    }

    static func indexedSeriesPredicate(excluding excluded: Set<String>) -> Predicate<Series> {
        let (ids, filters) = excludedOptional(excluded)
        return #Predicate {
            $0.indexedAt != nil && (!filters || $0.categoryId == nil || !ids.contains($0.categoryId))
        }
    }
}
