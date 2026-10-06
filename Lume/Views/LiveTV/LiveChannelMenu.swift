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
    ///   - stream: the channel the Record item acts on; the item hides itself
    ///     where no record flow is installed, no server is paired, or the
    ///     playlist can't record.
    ///   - isFavorite: drives the favorite item's wording and glyph.
    ///   - onStartMultiView: omitted where Multi-View has no entry point.
    ///   - onRemoveFromRecents: only in the Recently Watched collection.
    func liveChannelMenu(
        stream: LiveStream,
        isFavorite: Bool,
        onToggleFavorite: @escaping () -> Void,
        onStartMultiView: (() -> Void)? = nil,
        onRemoveFromRecents: (() -> Void)? = nil
    ) -> some View {
        contextMenu {
            FavoriteMenuItems.favorite(isFavorite: isFavorite, action: onToggleFavorite)

            if let onStartMultiView {
                FavoriteMenuItems.startMultiView(onStartMultiView)
            }

            FavoriteMenuItems.record(stream: stream)

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

    static func startMultiView(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Start Multi-View", systemImage: "rectangle.split.2x2")
        }
    }

    /// The same titles as plain strings, for UIKit accessibility actions.
    static func favoriteTitle(isFavorite: Bool) -> String {
        isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
    }

    static var startMultiViewTitle: String {
        String(localized: "Start Multi-View")
    }

    static func removeFromRecents(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label("Remove from Recently Watched", systemImage: "clock.badge.xmark")
        }
    }

    static func record(stream: LiveStream) -> some View {
        LiveChannelRecordButton(stream: stream)
    }
}

/// Its own view so the recording-state read is tracked here, not by the row
/// that owns the menu — a refresh that changes the recordings then re-renders
/// this item alone. The screens hosting these menus don't poll, so the item
/// refreshes stale recordings when the menu builds it.
private struct LiveChannelRecordButton: View {
    let stream: LiveStream
    @Environment(\.recordChannel) private var recordChannel

    var body: some View {
        if let recordChannel, let state = recordChannel.channelState(for: stream) {
            Button {
                recordChannel(stream)
            } label: {
                switch state {
                case .record:
                    Label("Record", systemImage: "record.circle")
                case .stop:
                    Label("Stop Recording", systemImage: "stop.circle")
                case .locked:
                    Label("Record", systemImage: "crown")
                }
            }
            .task { await RecordingServerStore.shared.refreshIfStale(maxAge: .seconds(30)) }
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
