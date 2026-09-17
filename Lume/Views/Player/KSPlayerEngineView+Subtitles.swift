//
//  KSPlayerEngineView+Subtitles.swift
//  Lume
//
//  The KSPlayer host's side of the OpenSubtitles integration: whether to offer
//  the in-player search, and how a downloaded file reaches the running player.
//  Split out of `KSPlayerEngineView` to keep that type inside the SwiftLint
//  body-length budget.
//

import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    /// Raises the OpenSubtitles browser, or `nil` when this stream can't use it
    /// (a live channel, or no API key in the build). A `nil` action also drops
    /// the entry from the overlay's subtitle menu.
    var subtitleSearchAction: (() -> Void)? {
        guard OpenSubtitlesService.supportsSearch(for: media) else { return nil }
        #if os(tvOS)
            guard engine.supportsExternalSubtitles else { return nil }
        #endif
        return { isSearchingSubtitles = true }
    }

    /// Loads a downloaded subtitle file into the running player. On tvOS this
    /// goes through the overlay's adapter so its track menu republishes; the
    /// adapter forwards to the same coordinator.
    func applyExternalSubtitle(_ subtitle: ExternalSubtitle) {
        #if os(tvOS)
            engine.loadExternalSubtitle(subtitle)
        #else
            coordinator.loadExternalSubtitle(subtitle)
        #endif
    }
}
