//
//  MovieCardView.swift
//  Lume
//
//  Card view for displaying a movie poster and title
//

import SwiftUI

struct MovieCardView: View {
    let movie: Movie

    var body: some View {
        VStack(alignment: .leading, spacing: PosterCardMetrics.titleSpacing) {
            // Poster
            CachedAsyncImage(url: URL(string: movie.streamIcon ?? ""), maxPixelSize: PosterCardMetrics.posterHeight) { phase in
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
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                                .font(.largeTitle)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
            // A shadow applied after clipShape forces an offscreen render pass per
            // card every frame. On tvOS the focus style already supplies depth and
            // a 2pt shadow is invisible on the 10-foot UI, so we skip it there.
            #if !os(tvOS)
                .shadow(radius: 2)
            #endif

            // Title
            Text(movie.name)
                .font(PosterCardMetrics.titleFont)
                .lineLimit(2)
                .frame(width: PosterCardMetrics.posterWidth, alignment: .leading)
        }
    }
}

#Preview("Basic") {
    MovieCardView(
        movie: Movie(
            id: "preview-1",
            streamId: 1,
            name: "Sample Movie",
            streamIcon: nil
        )
    )
}

#Preview("With Poster") {
    MovieCardView(
        movie: Movie(
            id: "preview-2",
            streamId: 2,
            name: "The Matrix",
            streamIcon: "https://image.tmdb.org/t/p/w185/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg",
            rating: 8.7,
            rating5Based: 4.4
        )
    )
}

#Preview("With TMDB") {
    let movie = Movie(
        id: "preview-3",
        streamId: 3,
        name: "Inception",
        streamIcon: "https://image.tmdb.org/t/p/w185/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg",
        rating: 8.8,
        rating5Based: 4.5
    )
    movie.tmdbId = 27205
    movie.contentRating = "PG-13"
    movie.plot = "A thief who steals corporate secrets through dream-sharing technology."
    return MovieCardView(movie: movie)
}
