//
//  LumeEngineEngineView+Failures.swift
//  Lume
//
//  What the LumeEngine host does when a stream fails to start or drops, kept
//  out of the main file (which is at its length cap).
//

import SwiftUI

extension LumeEngineEngineView {
    /// Mid-stream drop: bounded backoff, then give up loudly.
    func reconnect(after failure: LumeEngineFailure) {
        let showsFailure = reconnector.reconnect(
            after: failure,
            engine: "LumeEngine",
            refreshStreamURL: refreshStreamURL,
            holdURLRefresh: { urlRefresh = $0 },
            reload: { coordinator.reload(replacingURL: $0) }
        )
        if showsFailure {
            withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
        }
    }

    /// The coordinator reported it can't start the stream. On an initial-load
    /// failure with a fallback engine available, hand off to the host (which
    /// switches engines); otherwise raise the failure overlay. A 404 skips the
    /// fallback: every engine would be asking for the same missing stream.
    func reportFailure(_ failure: LumeEngineFailure) {
        guard !loadFailed else { return }
        if failure.handsOffStartupFailure(
            engine: "LumeEngine",
            reportsStartupFailure: reportsStartupFailure,
            hasStartedPlayback: coordinator.hasStartedPlayback
        ) {
            onPlaybackFailed?()
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
    }
}
