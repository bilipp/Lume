//
//  KSPlayerEngineView+StreamInfo.swift
//  Lume
//
//  Keeps `videoInfo` current for the iOS / macOS / visionOS stream-info caption,
//  kept out of the main file (which is at its length cap).
//
//  tvOS gets the same values through `KSTVPlaybackEngine`, which calls the very
//  same `KSVideoInfo.resolve(from:)`.
//

import KSPlayer
import SwiftUI

#if !os(tvOS)

    @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
    extension KSPlayerEngineView {
        /// Re-read the video track's resolution / frame rate / codec. Cheap and
        /// idempotent; only republishes when the value actually changes.
        ///
        /// Driven by KSPlayer's state transitions only. It must never be called
        /// from the 10 Hz `onPlay` tick: `videoInfo` feeds the controls overlay,
        /// and a per-tick republish makes an open audio / subtitle menu flicker
        /// and swallow taps.
        func refreshVideoInfo() {
            let info = KSVideoInfo.resolve(from: coordinator.playerLayer)
            if info != videoInfo { videoInfo = info }
        }

        /// The one exception to the rule above, for the 10 Hz `onPlay` tick:
        /// `KSVideoInfo.resolve` returns `nil` until the track reports usable
        /// dimensions, and after `.bufferFinished` no further state transition
        /// follows — so without this chase the technical half of the caption can
        /// stay missing for the whole session. Gated on `nil`, it republishes at
        /// most once and never becomes a per-tick read.
        func chaseVideoInfo() {
            if videoInfo == nil { refreshVideoInfo() }
        }

        /// Drop the snapshot when the host swaps streams, so the outgoing
        /// track's numbers never caption the incoming one.
        func resetVideoInfo() {
            if videoInfo != nil { videoInfo = nil }
        }
    }

#endif
