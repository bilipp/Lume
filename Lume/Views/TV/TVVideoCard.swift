//
//  TVVideoCard.swift
//  Lume
//
//  tvOS card for the YouTube videos rail on the movie and series detail
//  screens: the video thumbnail with a centered play glyph, then the video
//  name and kind.
//

#if os(tvOS)

    import SwiftUI

    /// A large 16:9 card for the YouTube videos rail: the video thumbnail with a
    /// centered play glyph, then the video name and kind. Selecting it best-effort
    /// opens the video in the YouTube app via its universal link.
    struct TVVideoCard: View {
        let video: TitleVideo
        let onSelect: () -> Void

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        AsyncImage(url: video.thumbnailURL) { phase in
                            switch phase {
                            case let .success(image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .empty:
                                Rectangle().fill(Color.white.opacity(0.08)).overlay { ProgressView() }
                            default:
                                Rectangle().fill(Color.white.opacity(0.08))
                                    .overlay {
                                        Image(systemName: "play.rectangle")
                                            .font(.system(size: 44))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                            }
                        }
                        .frame(width: TVDetailMetrics.episodeCardWidth, height: TVDetailMetrics.episodeStillHeight)
                        .clipped()

                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                    }
                    .frame(width: TVDetailMetrics.episodeCardWidth, height: TVDetailMetrics.episodeStillHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(video.name)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(video.type)
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(width: TVDetailMetrics.episodeCardWidth, alignment: .leading)
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
        }
    }

#endif
