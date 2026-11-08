//
//  LibraryCategoryLayout.swift
//  Lume
//
//  How the Movies and Series browse screens split their categories into the
//  inline preview rows and the "Show All" tile grid, grouped by Combined member.
//

import Foundation

/// Categories are grouped by owning playlist in member priority order and never
/// merged by name. The preview rows take the first few categories overall; the
/// rest form one tile group per member. Groups carry a title only when two or
/// more members contribute the type, so a single playlist lays out exactly as
/// it did before Combined existed.
struct LibraryCategoryLayout {
    struct Group: Identifiable {
        /// The member playlist.
        let id: UUID
        /// The member's name; nil when only one member contributes the type.
        let title: String?
        let categories: [Category]
    }

    let previews: [Category]
    let remaining: [Group]

    var isEmpty: Bool {
        previews.isEmpty
    }

    /// `members` are the scope's members contributing the type, in priority
    /// order (`[Playlist].members(of:for:)`).
    static func make(
        categories: [Category],
        members: [(id: UUID, name: String)],
        sort: CategorySortOption,
        restriction: ContentRestriction,
        previewLimit: Int
    ) -> LibraryCategoryLayout {
        let isGrouped = members.count > 1
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var previews: [Category] = []
        var remaining: [Group] = []
        for (member, owned) in CatalogScope.grouped(categories, byMember: members.map(\.id), id: \.id) {
            let sorted = sort.sort(owned.filter { !restriction.hides(categoryID: $0.id) })
            let previewCount = min(max(previewLimit - previews.count, 0), sorted.count)
            previews += sorted.prefix(previewCount)
            let rest = Array(sorted.dropFirst(previewCount))
            guard !rest.isEmpty else { continue }
            remaining.append(Group(id: member, title: isGrouped ? names[member] : nil, categories: rest))
        }
        return LibraryCategoryLayout(previews: previews, remaining: remaining)
    }
}
