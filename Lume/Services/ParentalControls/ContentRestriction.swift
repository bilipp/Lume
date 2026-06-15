//
//  ContentRestriction.swift
//  Lume
//
//  Describes which content is hidden from the current viewer because of parental
//  controls. `MainTabView` builds it from the restricted categories and the
//  active profile's `isChild` flag and injects it into the environment; every
//  content surface (browse grids, the cross-category rows, Home and Search)
//  reads it so restricted categories — and any title in them — disappear while a
//  child profile is active. A parent profile sees everything (`isActive` false).
//

import SwiftUI

nonisolated struct ContentRestriction: Equatable {
    /// True when the active profile is a child: restriction applies only to kids.
    var isActive = false
    /// Ids of the categories marked restricted.
    var restrictedCategoryIDs: Set<String> = []

    /// Whether content in `categoryID` should be hidden from the current viewer.
    func hides(categoryID: String?) -> Bool {
        guard isActive, let categoryID else { return false }
        return restrictedCategoryIDs.contains(categoryID)
    }
}

extension EnvironmentValues {
    @Entry var contentRestriction = ContentRestriction()
}

/// Content that belongs to a `Category`, so it can be filtered when that category
/// is restricted. Movies, series and live channels all carry a `categoryId`.
protocol CategorizedContent {
    var categoryId: String? { get }
}

extension Movie: CategorizedContent {}
extension Series: CategorizedContent {}
extension LiveStream: CategorizedContent {}

extension Sequence where Element: CategorizedContent {
    /// Drops items whose category is restricted for the current viewer. A no-op
    /// when restriction is inactive (a parent profile) or nothing is restricted.
    func excludingRestricted(_ restriction: ContentRestriction) -> [Element] {
        guard restriction.isActive, !restriction.restrictedCategoryIDs.isEmpty else {
            return Array(self)
        }
        return filter { !restriction.restrictedCategoryIDs.contains($0.categoryId ?? "") }
    }
}
