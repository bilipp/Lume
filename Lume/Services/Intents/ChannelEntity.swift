//
//  ChannelEntity.swift
//  Lume
//

import AppIntents
import Foundation
import SwiftData

/// A live channel Siri can play by name.
nonisolated struct ChannelEntity: IntentCatalogEntity {
    static let kind = IntentContentKind.channel
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Channel"
    static let defaultQuery = ChannelEntityQuery()

    let id: String
    let title: String
    let playlistName: String
    let showsPlaylistName: Bool
}

nonisolated struct ChannelEntityQuery: IntentCatalogEntityQuery {
    typealias Entity = ChannelEntity

    @Dependency var catalog: ModelContainer
    @Dependency var profiles: ProfileManager
}
