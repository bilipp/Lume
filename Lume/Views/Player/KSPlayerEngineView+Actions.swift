//
//  KSPlayerEngineView+Actions.swift
//  Lume
//
//  The transport actions every platform's KSPlayer chrome drives — play/pause,
//  the controls auto-hide timer, the lock-screen transport handoff and closing
//  the player. Kept out of the main file, which is at its length cap.
//

import KSPlayer
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

extension KSPlayerEngineView {
    /// Hands the session's remote-command transport to `NowPlayingService`.
    /// KSPlayer's own remote-command registration is disabled (see
    /// `makeOptions`), so this is the only handler set.
    func attachNowPlayingTransport() {
        NowPlayingService.shared.attachTransport(.init(
            isPlaying: { [weak coordinator] in coordinator?.playerLayer?.state.isPlaying ?? false },
            play: { [weak coordinator] in coordinator?.playerLayer?.play() },
            pause: { [weak coordinator] in coordinator?.playerLayer?.pause() },
            seek: { [weak coordinator] in coordinator?.seek(time: $0) },
            advance: onRemoteAdvance
        ), owner: coordinator)
    }

    func applyTimeshiftOffsetIfNeeded() {
        #if os(macOS)
            guard timeshift != nil, !appliedTimeshiftOffset, media.startTime > 0,
                  let player = coordinator.playerLayer?.player else { return }
            appliedTimeshiftOffset = true
            // Initial HLS opens can round to a segment boundary. Seek after
            // decoding starts so KSPlayer's accurate frame-discard pass runs.
            player.seek(time: media.startTime) { _ in }
        #endif
    }

    func skipTimeshiftOrMedia(_ seconds: TimeInterval) {
        #if os(macOS)
            if let timeshift { timeshift.skip(seconds, clock: clock); return }
        #endif
        if media.programmeDuration != nil {
            let end = clock.displayDuration(growing: media.recordingTimeline)
            coordinator.seek(time: min(max(0, clock.current + seconds), end))
        } else {
            coordinator.skip(interval: Int(seconds))
        }
    }

    func togglePlay() {
        #if os(macOS)
            if let timeshift, !(coordinator.playerLayer?.state.isPlaying ?? false), timeshift.resumeIfExpired(clock: clock) { return }
        #endif
        let playing: Bool
        #if os(tvOS)
            playing = engine.isPlaying
        #else
            playing = isPlaying
        #endif
        if playing {
            coordinator.playerLayer?.pause()
        } else {
            coordinator.playerLayer?.play()
        }
        #if os(tvOS)
            // Reflect the new state immediately so the glyph flips without
            // waiting for the next state callback.
            engine.syncState(playing ? .paused : .bufferFinished)
        #endif
        resetHideTimer()
    }

    func resetHideTimer() {
        hideTask?.cancel()
        if isControlsVisible {
            scheduleHide()
        }
    }

    func showControls() {
        guard !isControlsVisible else { resetHideTimer(); return }
        withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
        scheduleHide()
    }

    func scheduleHide() {
        hideTask?.cancel()
        #if os(tvOS)
            guard engine.isPlaying, !isPanelOpen else { return }
        #else
            guard isPlaying, !PlayerControlsAutoHide.isSuppressed else { return }
        #endif
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(autoHideInterval * 1_000_000_000))
            if await PlayerControlsAutoHide.waitWhileMenuOpen() {
                try? await Task.sleep(nanoseconds: UInt64(autoHideInterval * 1_000_000_000))
            }
            #if os(tvOS)
                guard !Task.isCancelled, engine.isPlaying else { return }
            #else
                guard !Task.isCancelled, isPlaying else { return }
            #endif
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible = false
            }
        }
    }

    func closePlayer() {
        #if os(macOS)
            timeshift?.stop()
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            dismissWindow(id: "player")
        #else
            dismiss.dismissPlayer()
        #endif
    }
}
