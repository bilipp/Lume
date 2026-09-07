//
//  KSPlayerEngineView+Controls.swift
//  Lume
//
//  The iOS / macOS / visionOS controls overlay mount and its tap toggle, kept
//  out of the main file (which is at its length cap). tvOS builds its chrome
//  from `TVPlayerControlsOverlay` instead.
//

import KSPlayer
import SwiftUI

#if !os(tvOS)

    @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
    extension KSPlayerEngineView {
        var controlsOverlay: some View {
            KSPlayerControlsOverlay(
                coordinator: coordinator,
                media: media,
                isPlaying: $isPlaying,
                isSeeking: $isSeeking,
                seekPosition: $seekPosition,
                clock: clock,
                isPipActive: $isPipActive,
                hideTask: $hideTask,
                onClose: { closePlayer() },
                onTogglePlay: { togglePlay() },
                onResetHideTimer: { resetHideTimer() },
                onScheduleHide: { scheduleHide() },
                onSearchSubtitles: subtitleSearchAction,
                videoInfo: videoInfo
            )
        }

        func toggleControls() {
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible.toggle()
            }
            if isControlsVisible {
                scheduleHide()
            }
        }
    }

#endif
