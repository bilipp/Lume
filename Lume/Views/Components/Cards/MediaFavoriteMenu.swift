//
//  MediaFavoriteMenu.swift
//  Lume
//
//  The VOD twin of `LiveChannelMenu`: the secondary actions on a movie or
//  series card — long-press on iOS, iPadOS and tvOS, right-click on macOS,
//  pinch-and-hold on visionOS. One menu rather than several stacked modifiers:
//  only the outermost `contextMenu` survives on a view, so every action a card
//  offers has to be built here, which is why the recents-removal and
//  recommendation-vote items are parameters rather than separate modifiers.
//
//  Attach it to the `NavigationLink` / `Button` *after* the card button style,
//  never inside the card's label view — a label is invisible to the tvOS focus
//  engine and gets shadowed by the outer menu at grid call sites.
//

import SwiftData
import SwiftUI
#if os(iOS)
    import UIKit
#endif

extension View {
    /// - Parameters:
    ///   - isFavorite: drives the favorite item's wording and glyph. A closure,
    ///     not a value, so the read happens inside the `contextMenu` builder
    ///     when the menu is presented. Read eagerly at a rail or grid call site
    ///     it would make the *container* observe every cell's `isFavorite`, so
    ///     one toggle would invalidate the whole lazy grid's body — the cost
    ///     class that drives tvOS focus and accessibility responder walks.
    ///   - onRemoveFromRecents: only in the Recently Watched collections.
    ///   - onVote: only on "For You" recommendations.
    func mediaFavoriteMenu(
        isFavorite: @escaping () -> Bool,
        onToggleFavorite: @escaping () -> Void,
        onRemoveFromRecents: (() -> Void)? = nil,
        onVote: ((RecommendationVote) -> Void)? = nil
    ) -> some View {
        contextMenu {
            FavoriteMenuItems.favorite(isFavorite: isFavorite()) {
                onToggleFavorite()
                favoriteToggleFeedback()
            }

            if let onVote {
                Button {
                    onVote(.upvote)
                } label: {
                    Label("More Like This", systemImage: "hand.thumbsup")
                }
                Button(role: .destructive) {
                    onVote(.downvote)
                } label: {
                    Label("Not Interested", systemImage: "hand.thumbsdown")
                }
            }

            if let onRemoveFromRecents {
                FavoriteMenuItems.removeFromRecents(onRemoveFromRecents)
            }
        }
    }
}

extension View {
    /// The favorite menu for a `HomeMediaItem` entry: the home rows and the
    /// detail-screen poster rails. Live channels keep `liveChannelMenu` and are
    /// left untouched here.
    @ViewBuilder
    func mediaFavoriteMenu(
        _ item: HomeMediaItem,
        in context: ModelContext,
        onRemoveFromRecents: (() -> Void)? = nil,
        onVote: ((RecommendationVote) -> Void)? = nil
    ) -> some View {
        switch item {
        case let .movie(movie):
            mediaFavoriteMenu(
                isFavorite: { movie.isFavorite },
                onToggleFavorite: { MediaFavorites.toggle(movie, in: context) },
                onRemoveFromRecents: onRemoveFromRecents,
                onVote: onVote
            )
        case let .series(series):
            mediaFavoriteMenu(
                isFavorite: { series.isFavorite },
                onToggleFavorite: { MediaFavorites.toggle(series, in: context) },
                onRemoveFromRecents: onRemoveFromRecents,
                onVote: onVote
            )
        case .live:
            self
        }
    }
}

extension View {
    /// The favorite menu for a downloaded episode row. Favoriting an episode
    /// favorites its show — episodes have no `isFavorite` of their own, the same
    /// routing `PlayerFavorites` uses. An orphan episode gets no menu rather
    /// than one whose favorite item would silently do nothing.
    @ViewBuilder
    func episodeFavoriteMenu(_ episode: Episode, in context: ModelContext) -> some View {
        if let series = episode.series {
            mediaFavoriteMenu(
                isFavorite: { series.isFavorite },
                onToggleFavorite: { MediaFavorites.toggle(series, in: context) }
            )
        } else {
            self
        }
    }
}

extension View {
    /// The favorite menu for the home hero. The hero's Details affordance is
    /// the only element it owns — on tvOS the only focusable one, and the one
    /// the hero-collapse behaviour depends on — so the menu attaches there
    /// rather than to the carousel surface, which owns swipe paging.
    ///
    /// Deliberately NOT a `@ViewBuilder` branching on movie⇄series: the tvOS
    /// hero pill is one structurally stable Button across every slide, and a
    /// conditional branch here would hand it a new identity on the pages that
    /// switch kind — focus falls to the first row and the whole home jumps.
    func heroFavoriteMenu(_ hero: HeroItem, in context: ModelContext) -> some View {
        mediaFavoriteMenu(
            isFavorite: { hero.movie?.isFavorite ?? hero.series?.isFavorite ?? false },
            onToggleFavorite: {
                if let movie = hero.movie {
                    MediaFavorites.toggle(movie, in: context)
                } else if let series = hero.series {
                    MediaFavorites.toggle(series, in: context)
                }
            }
        )
    }
}

/// Confirmation for the favorite toggle. iPhone / iPad only by product
/// decision — visionOS is `os(visionOS)` and deliberately gets nothing. Fired
/// imperatively from the menu action rather than through `sensoryFeedback`,
/// which would put trigger state on every VOD card for a one-shot response to a
/// discrete tap.
private func favoriteToggleFeedback() {
    #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
}
