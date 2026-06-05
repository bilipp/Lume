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

/// Opens a video in the YouTube app (or the system browser, where one exists).
///
/// Platform behaviour differs because the hand-off mechanism differs:
/// - **macOS / iOS**: the `https` watch URL is a universal link the system
///   routes to the YouTube app, falling back to a browser if it isn't installed.
/// - **tvOS**: there is no browser and `https` universal links are *not* routed
///   to other apps, so the only way to open a trailer is the YouTube app's
///   custom URL scheme. We try the candidate schemes in order and open the
///   first one the system can resolve. If none resolve (YouTube not installed,
///   or it no longer registers the scheme) `onUnavailable` is called so the
///   caller can surface that to the user instead of failing silently.
@MainActor
func openVideo(_ video: TitleVideo, onUnavailable: @escaping () -> Void = {}) {
    #if os(macOS)
        guard let url = video.youtubeURL else { return onUnavailable() }
        NSWorkspace.shared.open(url)
    #elseif os(tvOS)
        let app = UIApplication.shared
        guard let url = video.youtubeAppURLs.first(where: { app.canOpenURL($0) }) else {
            return onUnavailable()
        }
        app.open(url) { opened in
            if !opened { onUnavailable() }
        }
    #else
        guard let url = video.youtubeURL else { return onUnavailable() }
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
                CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: width) { phase in
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
