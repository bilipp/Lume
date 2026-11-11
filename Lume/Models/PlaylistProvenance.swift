//
//  PlaylistProvenance.swift
//  Lume
//
//  Which member playlist a live channel card came from, for the provenance
//  badge on the Live TV grids. Only while two or more Combined members
//  contribute Live TV does it carry names; isolated mode and a single
//  contributor resolve every id to `nil`, so those cards look as they always
//  have. Movies and series carry no badge: duplicates group into one card.
//

import Foundation
import SwiftUI

nonisolated struct PlaylistProvenance: Equatable {
    private struct Label: Equatable {
        let prefix: String
        let name: String
    }

    private let labels: [Label]

    static let none = PlaylistProvenance(labels: [])

    private init(labels: [Label]) {
        self.labels = labels
    }

    init(scope: CatalogScope, names: [UUID: String]) {
        guard scope.isCombined, scope.namesMembers(for: .liveTV) else {
            self.init(labels: [])
            return
        }
        self.init(labels: zip(scope.members(for: .liveTV), scope.prefixes(for: .liveTV)).compactMap { id, prefix in
            names[id].map { Label(prefix: prefix, name: $0) }
        })
    }

    /// The badge for a live stream row, or `nil` to leave it off.
    func name(forStreamID streamID: String) -> String? {
        labels.first { streamID.hasPrefix($0.prefix) }?.name
    }
}

extension EnvironmentValues {
    /// Set with `catalogScope`, read by the channel cards. The Multi-View
    /// picker sets `.none` to stay unbadged.
    @Entry var playlistProvenance = PlaylistProvenance.none
}

extension View {
    /// Publishes the content tabs' scope and the provenance their channel
    /// grids badge items with.
    func catalogScope(_ scope: CatalogScope, playlists: [Playlist]) -> some View {
        environment(\.catalogScope, scope)
            .environment(\.playlistProvenance, PlaylistProvenance(scope: scope, names: playlists.namesByID))
    }
}
