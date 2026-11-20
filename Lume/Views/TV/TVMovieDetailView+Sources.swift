//
//  TVMovieDetailView+Sources.swift
//  Lume
//
//  Which copy of a grouped movie Play opens on tvOS; the shared logic lives
//  in `TitleGroupMovieDetail`. A long press on Play always asks.
//

#if os(tvOS)

    import SwiftUI

    extension TVMovieDetailView: TitleGroupMovieDetail {
        /// The picker closed: play its pick, or hand focus back to Play.
        func sourcePickerDidClose() {
            guard let media = pendingMedia else {
                Task { @MainActor in focus = .play }
                return
            }
            pendingMedia = nil
            playingMedia = media
        }
    }

#endif
