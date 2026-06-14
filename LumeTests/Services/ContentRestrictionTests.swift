//
//  ContentRestrictionTests.swift
//  LumeTests
//
//  Covers the parental-control content filter: restricted categories (and the
//  content in them) are excluded only while a child profile is active, and a
//  parent profile keeps seeing everything.
//

import Foundation
@testable import Lume
import Testing

/// Minimal stand-in for a categorised content item (Movie/Series/LiveStream all
/// conform to `CategorizedContent`); lets the filter be tested without models.
private struct StubItem: CategorizedContent {
    let categoryId: String?
}

@MainActor
struct ContentRestrictionTests {
    @Test func `inactive restriction hides nothing`() {
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: ["a", "b"])
        #expect(restriction.hides(categoryID: "a") == false)
        #expect(restriction.hides(categoryID: "b") == false)
    }

    @Test func `active restriction hides only restricted categories`() {
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["a"])
        #expect(restriction.hides(categoryID: "a") == true)
        #expect(restriction.hides(categoryID: "b") == false)
    }

    @Test func `nil category is never hidden`() {
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["a"])
        #expect(restriction.hides(categoryID: nil) == false)
    }

    @Test func `excluding restricted drops matching items when active`() {
        let items = [StubItem(categoryId: "a"), StubItem(categoryId: "b"), StubItem(categoryId: nil)]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["a"])
        let kept = items.excludingRestricted(restriction)
        #expect(kept.map(\.categoryId) == ["b", nil])
    }

    @Test func `excluding restricted keeps everything for parent profile`() {
        let items = [StubItem(categoryId: "a"), StubItem(categoryId: "b")]
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: ["a"])
        #expect(items.excludingRestricted(restriction).count == 2)
    }

    @Test func `excluding restricted keeps everything when nothing restricted`() {
        let items = [StubItem(categoryId: "a"), StubItem(categoryId: "b")]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [])
        #expect(items.excludingRestricted(restriction).count == 2)
    }
}
