//
//  PlaylistProvenance.swift
//  Lume
//
//  Which member playlist a browse card's item came from, for the provenance
//  badge on the Movies, Series and Live TV grids. Only a tab that two or more
//  Combined members contribute to carries names; isolated mode and a
//  single-contributor tab resolve every id to `nil`, so those cards look as
//  they always have.
//

import Foundation
import SwiftUI

nonisolated struct PlaylistProvenance: Equatable {
    private struct Label: Equatable {
        let prefix: String
        let name: String
    }

    private let labels: [PlaylistTab: [Label]]

    static let none = PlaylistProvenance(labels: [:])

    private init(labels: [PlaylistTab: [Label]]) {
        self.labels = labels
    }

    init(scope: CatalogScope, names: [UUID: String]) {
        var labels: [PlaylistTab: [Label]] = [:]
        if scope.isCombined {
            for tab in PlaylistTab.allCases {
                guard scope.namesMembers(for: tab) else { continue }
                labels[tab] = zip(scope.members(for: tab), scope.prefixes(for: tab)).compactMap { id, prefix in
                    names[id].map { Label(prefix: prefix, name: $0) }
                }
            }
        }
        self.init(labels: labels)
    }

    /// The badge for a catalog row on `tab`'s grids, or `nil` to leave it off.
    func name(forContentID contentID: String, in tab: PlaylistTab) -> String? {
        labels[tab]?.first { contentID.hasPrefix($0.prefix) }?.name
    }
}

extension EnvironmentValues {
    /// Set with `catalogScope`, read by the poster and channel cards. Category
    /// preview rows and the Multi-View picker set `.none` to stay unbadged.
    @Entry var playlistProvenance = PlaylistProvenance.none
}

extension View {
    /// Publishes the content tabs' scope and the provenance their grids badge
    /// items with.
    func catalogScope(_ scope: CatalogScope, playlists: [Playlist]) -> some View {
        environment(\.catalogScope, scope)
            .environment(\.playlistProvenance, PlaylistProvenance(scope: scope, names: playlists.namesByID))
    }
}
