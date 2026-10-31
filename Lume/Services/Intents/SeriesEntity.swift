//
//  SeriesEntity.swift
//  Lume
//

import AppIntents
import Foundation
import SwiftData

/// A series Siri can play by name; the episode is picked when it plays.
nonisolated struct SeriesEntity: IntentCatalogEntity {
    static let kind = IntentContentKind.series
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Series"
    static let defaultQuery = SeriesEntityQuery()

    let id: String
    let title: String
    let playlistName: String
    let showsPlaylistName: Bool
}

nonisolated struct SeriesEntityQuery: IntentCatalogEntityQuery {
    typealias Entity = SeriesEntity

    @Dependency var catalog: ModelContainer
    @Dependency var profiles: ProfileManager
}
