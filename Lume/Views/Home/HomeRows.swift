//
//  HomeRows.swift
//  Lume
//
//  The horizontal rails on the Home screen (Recently Watched, Trending, etc.)
//  and the poster cards they contain. Extracted from `HomeView` to keep that
//  file focused on data loading and screen composition.
//

import SwiftUI

// MARK: - Row

struct HomeRow: View {
    let title: LocalizedStringKey
    let items: [HomeMediaItem]
    let onPlayLive: (LiveStream) -> Void
    /// When set, each card gains a "Remove from Recently Watched" context menu.
    /// Only the Recently Watched row passes this; the others leave it nil.
    var onRemove: ((HomeMediaItem) -> Void)?
    var animationNamespace: Namespace.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PosterCardMetrics.railSpacing) {
                    ForEach(items) { item in
                        HomeItemCell(item: item, onPlayLive: onPlayLive, onRemove: onRemove, animationNamespace: animationNamespace)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, PosterCardMetrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .frame(height: PosterCardMetrics.rowHeight)
        }
    }
}

private struct HomeItemCell: View {
    let item: HomeMediaItem
    let onPlayLive: (LiveStream) -> Void
    var onRemove: ((HomeMediaItem) -> Void)?
    var animationNamespace: Namespace.ID?

    var body: some View {
        Group {
            switch item {
            case let .movie(movie):
                NavigationLink(value: movie) {
                    HomePosterCard(title: item.title, imageURL: item.imageURL, progress: item.progress)
                        .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .series(series):
                NavigationLink(value: series) {
                    HomePosterCard(title: item.title, imageURL: item.imageURL, progress: item.progress)
                        .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .live(stream):
                Button {
                    onPlayLive(stream)
                } label: {
                    HomePosterCard(title: item.title, imageURL: item.imageURL, isLive: true)
                }
                .posterCardButtonStyle()
            }
        }
        .recentlyWatchedRemoveMenu(onRemove.map { action in { action(item) } })
    }
}

// MARK: - Poster card

/// A poster-style card used across all home rows. Shows artwork with an
/// optional resume progress bar and a "Live" badge.
private struct HomePosterCard: View {
    let title: String
    let imageURL: URL?
    var progress: Double?
    var isLive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: PosterCardMetrics.titleSpacing) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: imageURL, maxPixelSize: PosterCardMetrics.posterHeight) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay { ProgressView() }
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: isLive ? .fit : .fill)
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay {
                                Image(systemName: isLive ? "antenna.radiowaves.left.and.right" : "film")
                                    .foregroundStyle(.secondary)
                                    .font(.largeTitle)
                            }
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)

                if isLive {
                    Text("LIVE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .padding(6)
                }

                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
            .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
            .shadow(radius: 2)

            Text(title)
                .font(PosterCardMetrics.titleFont)
                .lineLimit(2)
                .frame(width: PosterCardMetrics.posterWidth, alignment: .leading)
        }
    }
}
