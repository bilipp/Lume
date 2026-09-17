//
//  PlayerFavorites.swift
//  Lume
//
//  Cross-platform favorite resolution + toggle for the active player media.
//  Shared by all three control overlays (the tvOS `TVPlayerControlsOverlay`,
//  and the iOS / macOS KSPlayer and VLCKit overlays) so the favorite control
//  sitting beside the audio / subtitle track menus behaves identically on
//  every engine. Series are favorited via their parent (episodes have no
//  `isFavorite` of their own). Movies and series share the one VOD favorite
//  semantic in `MediaFavorites`; live streams toggle the flag alone.
//

import Foundation
import SwiftData

enum PlayerFavorites {
    /// Whether the content behind `ref` is currently favorited.
    static func isFavorite(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Bool {
        switch ref {
        case let .episode(id):
            PlayerContentLookup.episode(id, in: context)?.series?.isFavorite ?? false
        case let .movie(id):
            PlayerContentLookup.movie(id, in: context)?.isFavorite ?? false
        case let .live(id):
            PlayerContentLookup.liveStream(id, in: context)?.isFavorite ?? false
        }
    }

    /// Flip the favorite state, persist, and return the new value (defaulting
    /// to the prior state if the backing model can't be resolved).
    @discardableResult
    static func toggle(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Bool {
        switch ref {
        case let .episode(id):
            guard let resolved = PlayerContentLookup.episode(id, in: context) else { return false }
            return MediaFavorites.toggle(resolved, in: context)
        case let .movie(id):
            guard let resolved = PlayerContentLookup.movie(id, in: context) else { return false }
            return MediaFavorites.toggle(resolved, in: context)
        case let .live(id):
            guard let stream = PlayerContentLookup.liveStream(id, in: context) else { return false }
            return LiveChannelFavorites.toggle(stream, in: context)
        }
    }
}
