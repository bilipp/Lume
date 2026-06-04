//
//  VideoComponents.swift
//  Lume
//
//  The YouTube videos rail shown on the movie and series detail screens, plus
//  the cross-platform helper that opens a selected video in the YouTube app or
//  the system browser.
//

import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

/// Opens a video URL in the YouTube app (if installed) or the system browser.
/// On tvOS this best-effort hands off to the YouTube app via its universal link.
@MainActor
func openVideoURL(_ url: URL) {
    #if os(macOS)
        NSWorkspace.shared.open(url)
    #else
        UIApplication.shared.open(url)
    #endif
}

// MARK: - Videos

/// Horizontal row of YouTube videos (trailers, teasers, clips) from TMDB. Each
/// card shows the video's thumbnail with a play glyph; selecting one opens it in
/// the YouTube app or browser.
struct VideoRow: View {
    let videos: [TitleVideo]
    let onSelect: (TitleVideo) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(videos) { video in
                    Button {
                        onSelect(video)
                    } label: {
                        VideoThumbnailCard(video: video)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DetailMetrics.contentPadding)
        }
    }
}

private struct VideoThumbnailCard: View {
    let video: TitleVideo

    private let width: CGFloat = 240
    private let height: CGFloat = 135

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                AsyncImage(url: video.thumbnailURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        Rectangle().fill(Color.gray.opacity(0.25)).overlay { ProgressView() }
                    default:
                        Rectangle().fill(Color.gray.opacity(0.25))
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .frame(width: width, height: height)

            Text(video.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)

            Text(video.type)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: width, alignment: .leading)
        }
    }
}

#Preview("VideoRow") {
    let videos = [
        TitleVideo(key: "d6j_wN1QO7s", name: "Official Trailer", type: "Trailer"),
        TitleVideo(key: "m8e-FF8MsqU", name: "Teaser", type: "Teaser")
    ]
    return VideoRow(videos: videos) { _ in }
}
