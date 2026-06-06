//
//  ContentOrganizing.swift
//  Lume
//
//  Shared reorder / hide / reset logic for the Content Management feature.
//  Categories and live channels both carry a `customOrder` and an `isHidden`
//  flag, so the organizing operations are written once against a protocol and
//  reused for both.
//
//  Ordering convention: `customOrder` is `nil` until the user reorders a group,
//  at which point every member of that group is stamped with a dense index
//  (0, 1, 2, …). Keeping the assignment dense and all-or-nothing means a plain
//  `SortDescriptor(\.customOrder)` (nil-first) behaves correctly — an untouched
//  group all ties on nil and falls through to the provider order, while a
//  reordered group sorts purely by the user's choice. "Reset" clears the group
//  back to `nil`.
//

import Foundation
import SwiftUI // for Array.move(fromOffsets:toOffset:)

/// A piece of content the user can hide and reorder in Content Management.
protocol ContentItem: AnyObject {
    var customOrder: Int? { get set }
    var isHidden: Bool { get set }
}

extension Category: ContentItem {}
extension LiveStream: ContentItem {}

enum ContentOrganizer {
    /// Applies a SwiftUI `.onMove` to an already-sorted group and stamps a dense
    /// `customOrder` so the new arrangement persists.
    static func reorder(_ items: [some ContentItem], from source: IndexSet, to destination: Int) {
        var arranged = items
        arranged.move(fromOffsets: source, toOffset: destination)
        stampOrder(arranged)
    }

    /// Moves the item at `index` within an already-sorted group by `delta`
    /// positions (negative = up). Used by the tvOS move buttons, which have no
    /// drag gesture. No-ops when the move would leave the bounds.
    static func move(_ items: [some ContentItem], at index: Int, by delta: Int) {
        let target = index + delta
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        var arranged = items
        let moved = arranged.remove(at: index)
        arranged.insert(moved, at: target)
        stampOrder(arranged)
    }

    /// Clears the user-defined order for a group, reverting to provider order.
    static func resetOrder(_ items: [some ContentItem]) {
        for item in items {
            item.customOrder = nil
        }
    }

    /// Un-hides every item in a group.
    static func showAll(_ items: [some ContentItem]) {
        for item in items {
            item.isHidden = false
        }
    }

    private static func stampOrder(_ arranged: [some ContentItem]) {
        for (index, item) in arranged.enumerated() {
            item.customOrder = index
        }
    }
}
