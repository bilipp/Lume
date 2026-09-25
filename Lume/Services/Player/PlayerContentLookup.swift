//
//  PlayerContentLookup.swift
//  Lume
//
//  The by-id catalog lookups the player-side helpers share: the owning
//  playlist behind a `PlayableMedia.ContentRef`, and the models the ref points
//  at. Kept in one place so favorites, stream info and the Stalker resolver
//  can't drift on how a ref maps back onto the catalog.
//

import Foundation
import SwiftData

nonisolated enum PlayerContentLookup {
    /// Every catalog id embeds the owning playlist's UUID as its 36-character
    /// prefix, so the playlist is recoverable from the content reference alone.
    /// A miss returns `nil` — never a fallback to some other playlist, which
    /// would confidently name the wrong provider on a multi-playlist install.
    static func playlist(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Playlist? {
        let rawId: String = switch ref {
        case let .movie(id), let .episode(id), let .live(id):
            id
        }
        guard let playlistId = UUID(uuidString: String(rawId.prefix(36))) else { return nil }
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func episode(_ id: String, in context: ModelContext) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func movie(_ id: String, in context: ModelContext) -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func liveStream(_ id: String, in context: ModelContext) -> LiveStream? {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
