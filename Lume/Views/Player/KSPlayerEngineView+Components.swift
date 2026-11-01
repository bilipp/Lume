//
//  KSPlayerEngineView+Components.swift
//  Lume
//
//  The SwiftUI preview, split out of KSPlayerEngineView to keep that file
//  within the project's size limit.
//

import SwiftUI

#Preview("Fallback") {
    KSPlayerEngineView(
        media: PlayableMedia(
            id: "preview",
            url: URL(string: "https://example.com/stream.m3u8")!,
            title: "Sample Video",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .movie("preview")
        ),
        clock: PlaybackClock(),
        mediaSwapper: PlayerMediaSwapper()
    )
    .preferredColorScheme(.dark)
}
