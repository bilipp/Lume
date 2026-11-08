//
//  PlaylistOwner.swift
//  Lume
//
//  Resolves the playlist that owns a catalog row from the row's id. Every synced
//  id is written as "<playlist UUID>-<kind>-<provider id>" by `ContentSyncManager`,
//  so the owner is a single indexed lookup rather than a walk of every installed
//  playlist — which is what the player's neighbour resolvers used to do, once per
//  stream, on the main actor.
//

import Foundation
import SwiftData

nonisolated enum PlaylistOwner {
    /// The number of characters a canonical `UUID.uuidString` occupies. Ids are
    /// built from that exact spelling, so the owner's UUID is the leading slice.
    private static let uuidLength = 36

    /// The playlist whose UUID prefixes `id`, or `nil` when `id` names no
    /// installed playlist. Never another playlist in its place: with several
    /// playlists browsed together, any stand-in would build the stream URL
    /// against the wrong provider's credentials.
    static func playlist(forPrefixedID id: String, in context: ModelContext) -> Playlist? {
        guard let owner = declaredOwner(of: id) else { return nil }
        return playlist(withID: owner, in: context)
    }

    private static func playlist(withID id: UUID, in context: ModelContext) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The UUID `id` starts with, or `nil` when it doesn't start with one.
    /// Round-tripped through `uuidString` on purpose: the prefix scan this
    /// replaced matched that canonical spelling verbatim, and `UUID(uuidString:)`
    /// also accepts spellings it would have missed.
    private static func declaredOwner(of id: String) -> UUID? {
        guard id.count > uuidLength else { return nil }
        let candidate = String(id.prefix(uuidLength))
        guard let uuid = UUID(uuidString: candidate), uuid.uuidString == candidate else { return nil }
        return uuid
    }
}
