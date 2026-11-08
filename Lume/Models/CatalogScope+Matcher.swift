//
//  CatalogScope+Matcher.swift
//  Lume
//
//  In-memory scoping for rows that are already fetched, with each content
//  type's prefixes built once rather than per row.
//

import Foundation

nonisolated extension CatalogScope {
    nonisolated struct Matcher: Equatable {
        let scope: CatalogScope
        private let prefixesByTab: [PlaylistTab: [String]]
        private let rankedPrefixes: [String]

        init(_ scope: CatalogScope) {
            self.scope = scope
            prefixesByTab = Dictionary(uniqueKeysWithValues: PlaylistTab.allCases.map { ($0, scope.prefixes(for: $0)) })
            rankedPrefixes = scope.prefixes
        }

        /// Whether a row of `tab` belongs to the scope. With no playlist at all
        /// nothing is filtered, as before scopes existed.
        func contains(_ contentID: String, _ tab: PlaylistTab) -> Bool {
            guard !scope.isEmpty else { return true }
            return prefixesByTab[tab]?.contains { contentID.hasPrefix($0) } == true
        }

        /// The position of the row's playlist in the member priority order;
        /// `Int.max` for a row no member owns.
        func memberRank(of contentID: String) -> Int {
            rankedPrefixes.firstIndex { contentID.hasPrefix($0) } ?? .max
        }

        /// The member whose catalog the row belongs to.
        func member(of contentID: String) -> UUID? {
            rankedPrefixes.firstIndex { contentID.hasPrefix($0) }.map { scope.playlistIDs[$0] }
        }
    }
}

/// Holds the matcher across body passes, rebuilt only when the scope changes.
/// It carries no model objects, so a stale entry can never reach a deleted row.
@MainActor
final class CatalogScopeMatcherMemo {
    private var cached = CatalogScope.Matcher(.empty)

    func matcher(for scope: CatalogScope) -> CatalogScope.Matcher {
        if cached.scope != scope {
            cached = CatalogScope.Matcher(scope)
        }
        return cached
    }
}
