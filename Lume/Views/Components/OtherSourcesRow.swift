//
//  OtherSourcesRow.swift
//  Lume
//
//  The "Other Sources" strip on the movie/series detail screens: same-title
//  entries resolved by `OtherSources`, with entries from other playlists badged
//  with the owning playlist's name. The badge overlay is shared with the tvOS
//  rails via `posterBadge(_:)`.
//
//  Deliberately no favorite menu, unlike the sibling "You May Also Like" rail:
//  an entry here can be the same title on a *different* playlist, while the
//  Favorites rail is scoped to the active playlist, so favoriting that copy
//  would create a favorite the user can neither see nor undo on the rail they
//  were just looking at.
//

import SwiftUI

struct OtherSourcesRow: View {
    let sources: [OtherSources.Source]
    var animationNamespace: Namespace.ID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(sources) { source in
                    switch source.item {
                    case let .movie(movie):
                        NavigationLink(value: movie) {
                            DetailPosterCard(
                                title: source.item.title,
                                imageURL: source.item.imageURL,
                                badge: source.playlistName
                            )
                            .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                        }
                        .buttonStyle(.plain)
                    case let .series(series):
                        NavigationLink(value: series) {
                            DetailPosterCard(
                                title: source.item.title,
                                imageURL: source.item.imageURL,
                                badge: source.playlistName
                            )
                            .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                        }
                        .buttonStyle(.plain)
                    case .live:
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, DetailMetrics.contentPadding)
        }
    }
}

extension View {
    /// Overlays a playlist-name capsule on a poster's top-leading corner,
    /// sized for the 10-foot UI on tvOS. No-op when `badge` is nil.
    func posterBadge(_ badge: String?) -> some View {
        overlay(alignment: .topLeading) {
            if let badge {
                #if os(tvOS)
                    Text(badge)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: TVDetailMetrics.posterCardWidth - 40)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                #else
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 108)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                #endif
            }
        }
    }
}
