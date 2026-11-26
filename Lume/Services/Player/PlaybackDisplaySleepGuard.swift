//
//  PlaybackDisplaySleepGuard.swift
//  Lume
//
//  Keeps a Mac's display awake while a stream plays. Lume used to leave that
//  to the engines: KSPlayer takes a power assertion itself, but AetherEngine
//  only sets `preventsDisplaySleepDuringVideoPlayback` on its layer/player,
//  and users saw the display dim and sleep mid-playback with it (LumeEngine
//  sets nothing at all). Lume therefore holds its own, engine-agnostic one.
//
//  `NowPlayingService` drives it from the same play/pause state it publishes,
//  so it follows in-app, remote and engine-initiated pauses alike. Paused or
//  closed, the assertion is released and the Mac sleeps as usual.
//
//  iOS and tvOS are left alone: their idle timer is a single shared flag that
//  KSPlayer already toggles, and a second writer would race it.
//

#if os(macOS)
    import IOKit.pwr_mgt
    import OSLog

    final class PlaybackDisplaySleepGuard {
        static let shared = PlaybackDisplaySleepGuard()

        private var assertionID: IOPMAssertionID?

        private init() {}

        /// Whether the assertion is currently held.
        var isHeld: Bool {
            assertionID != nil
        }

        /// Hold the assertion while `playing`, release it otherwise. Idempotent,
        /// so callers can report the state as often as they publish it.
        func update(playing: Bool) {
            if playing {
                acquire()
            } else {
                release()
            }
        }

        func release() {
            guard let assertionID else { return }
            IOPMAssertionRelease(assertionID)
            self.assertionID = nil
        }

        private func acquire() {
            guard assertionID == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Lume video playback" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                Logger.player.error("Display sleep assertion refused: \(result, privacy: .public)")
                return
            }
            assertionID = id
        }
    }
#endif
