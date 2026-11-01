//
//  MovieEntity.swift
//  Lume
//

import AppIntents
import Foundation
import SwiftData

/// A movie Siri can start by name.
nonisolated struct MovieEntity: IntentCatalogEntity {
    static let kind = IntentContentKind.movie
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Movie"
    static let defaultQuery = MovieEntityQuery()

    let id: String
    let title: String
    let playlistName: String
    let showsPlaylistName: Bool
}

nonisolated struct MovieEntityQuery: IntentCatalogEntityQuery {
    typealias Entity = MovieEntity

    @Dependency var catalog: ModelContainer
    @Dependency var profiles: ProfileManager
}
