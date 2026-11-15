//
//  ContentRestriction+Queries.swift
//  Lume
//
//  Concrete predicates keep browse relocation inside SQLite. They can compose
//  with existing genre/scope predicates without another long macro expression.
//

import Foundation
import SwiftData

nonisolated extension ContentRestriction {
    static func movieBrowsePredicate(categories: Set<String>, content: Set<String>) -> Predicate<Movie> {
        let excluded = Set(categories.map(String?.some))
        return #Predicate {
            !content.contains($0.id) && ($0.categoryId == nil || !excluded.contains($0.categoryId))
        }
    }

    static func seriesBrowsePredicate(categories: Set<String>, content: Set<String>) -> Predicate<Series> {
        let excluded = Set(categories.map(String?.some))
        return #Predicate {
            !content.contains($0.id) && ($0.categoryId == nil || !excluded.contains($0.categoryId))
        }
    }
}
