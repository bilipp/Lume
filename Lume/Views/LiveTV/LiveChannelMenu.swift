//
//  LiveChannelMenu.swift
//  Lume
//
//  The secondary actions on a live channel row — long-press on iOS and tvOS,
//  right-click on macOS. One menu rather than several stacked modifiers: only
//  the outermost `contextMenu` survives on a view, so every action a channel
//  offers has to be built here.
//

import SwiftData
import SwiftUI

extension View {
    /// - Parameters:
    ///   - isFavorite: drives the favorite item's wording and glyph.
    ///   - onStartMultiView: omitted where Multi-View has no entry point.
    ///   - onRemoveFromRecents: only in the Recently Watched collection.
    func liveChannelMenu(
        isFavorite: Bool,
        onToggleFavorite: @escaping () -> Void,
        onStartMultiView: (() -> Void)? = nil,
        onRemoveFromRecents: (() -> Void)? = nil
    ) -> some View {
        contextMenu {
            FavoriteMenuItems.favorite(isFavorite: isFavorite, action: onToggleFavorite)

            if let onStartMultiView {
                Button(action: onStartMultiView) {
                    Label("Start Multi-View", systemImage: "rectangle.split.2x2")
                }
            }

            if let onRemoveFromRecents {
                FavoriteMenuItems.removeFromRecents(onRemoveFromRecents)
            }
        }
    }
}

/// The items `liveChannelMenu` and `mediaFavoriteMenu` both offer. The two menus
/// are twins by design, so their shared wording and glyphs live in one place —
/// a rename that only lands in one of them would create a fresh untranslated key
/// (see `MediaFavoriteMenuStringsTests`).
enum FavoriteMenuItems {
    static func favorite(isFavorite: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
    }

    static func removeFromRecents(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label("Remove from Recently Watched", systemImage: "clock.badge.xmark")
        }
    }
}

/// Flips a channel's favorite flag. Live streams toggle the flag alone — unlike
/// movies and series, which also stamp `addedToWatchlistDate` — mirroring
/// `PlayerFavorites` and the detail screens.
enum LiveChannelFavorites {
    @discardableResult
    static func toggle(_ stream: LiveStream, in context: ModelContext) -> Bool {
        stream.isFavorite.toggle()
        try? context.save()
        return stream.isFavorite
    }
}
