//
//  SearchResultRow.swift
//  Lume
//

import SwiftUI

struct SearchResultRow: View {
    let result: SearchResult
    /// Which playlist this row came from, or `nil` to leave the badge off.
    var playlistName: String?

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: thumbnailURL, maxPixelSize: 90) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            ProgressView()
                        }
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            Image(systemName: iconName)
                                .foregroundStyle(.secondary)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: categoryIcon)
                        Text(LocalizedStringKey(categoryName))
                    }
                    .foregroundStyle(.blue)
                    // Only present while searching across playlists, where the
                    // category alone doesn't say which provider a row is from.
                    if let playlistName {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.stack")
                            Text(playlistName)
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .font(.caption2)
            }

            Spacer()
        }
    }

    private var thumbnailURL: URL? {
        switch result {
        case let .movie(movie):
            URL(string: movie.streamIcon ?? "")
        case let .series(series):
            URL(string: series.cover ?? "")
        case let .liveStream(stream):
            URL(string: stream.streamIcon ?? "")
        }
    }

    private var title: String {
        switch result {
        case let .movie(movie):
            movie.name
        case let .series(series):
            series.name
        case let .liveStream(stream):
            stream.name
        }
    }

    private var subtitle: String {
        switch result {
        case let .movie(movie):
            movie.genre ?? movie.releaseDate ?? ""
        case let .series(series):
            series.genre ?? series.releaseDate ?? ""
        case .liveStream:
            "Live"
        }
    }

    private var categoryName: String {
        switch result {
        case .movie:
            "Movie"
        case .series:
            "Series"
        case .liveStream:
            "Live TV"
        }
    }

    private var categoryIcon: String {
        switch result {
        case .movie:
            "film"
        case .series:
            "tv"
        case .liveStream:
            "antenna.radiowaves.left.and.right"
        }
    }

    private var iconName: String {
        switch result {
        case .movie:
            "film"
        case .series:
            "tv"
        case .liveStream:
            "antenna.radiowaves.left.and.right"
        }
    }
}
