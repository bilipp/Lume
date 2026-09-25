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
                videoInfo: videoInfo,
                itemNeighbours: itemNeighbours,
                onStepItem: { stepItem($0) }
            )
        }

        /// Play the episode or channel on `step`'s side. Goes through the shared
        /// swapper — which drops a press that lands on the heels of the last one
        /// — and back out to the host, the only place allowed to change the
        /// stream: re-preparing this session in place frees the demuxer context
        /// under the decode threads.
        func stepItem(_ step: PlayerMediaSwapper.Step) {
            mediaSwapper.step(
                step,
                in: itemNeighbours,
                onCompleteCurrentItem: { onCompleteCurrentItem?() },
                select: { onSelectMedia?($0) }
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
