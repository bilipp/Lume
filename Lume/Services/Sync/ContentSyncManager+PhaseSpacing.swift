//
//  ContentSyncManager+PhaseSpacing.swift
//  Lume
//
//  Spacing between the Xtream content phases' bulk requests.
//

import Foundation
import OSLog

extension ContentSyncManager {
    /// Minimum gap between one content phase's last request and the next
    /// phase's first.
    static let contentPhaseRequestSpacing: Duration = .seconds(2)

    /// How much of `contentPhaseRequestSpacing` is still outstanding.
    ///
    /// Measured from when the request *finished*, not from when the phase
    /// returned — a phase spends tens of seconds decoding and writing after its
    /// download, and that time already spaces the requests. `nil` means nothing
    /// has been requested yet and nothing has to be spaced.
    nonisolated static func outstandingPhaseSpacing(
        since lastRequestFinishedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> Duration {
        guard let lastRequestFinishedAt else { return .zero }
        let remaining = contentPhaseRequestSpacing - (now - lastRequestFinishedAt)
        // Clamped at both ends: a negative gap means the spacing is already
        // paid for, and a clock that jumped backwards must not inflate it past
        // the configured spacing.
        return max(.zero, min(contentPhaseRequestSpacing, remaining))
    }

    /// Waits out whatever spacing the previous content phase did not already
    /// pay for, so the next bulk request does not race the provider's
    /// connection slot.
    ///
    /// Many Xtream accounts cap `max_connections` to 1 — which is why
    /// `XtreamClient.makeSession` pins the session to one connection per host
    /// and why `EPGSyncService.isContentSyncPending` stands down for the same
    /// slot. A request fired before the provider has released the previous
    /// connection comes back 401/403, and
    /// `XtreamClient.request(_:action:retryAuthFailure:)` then burns 2 s + 4 s
    /// of backoff on it, or the phase returns short and feeds the prune sweep a
    /// partial catalog. So the gap is enforced, but only against wall clock the
    /// sync has not already spent: a slow device pays nothing here, a fast one
    /// still spaces its requests.
    func spaceContentPhaseRequests() async throws {
        let remaining = await Self.outstandingPhaseSpacing(since: xtreamClient.lastRequestFinishedAt)
        guard remaining > .zero else {
            Logger.database.info("Xtream phase spacing already elapsed; continuing immediately")
            return
        }
        let seconds = remaining.seconds
        Logger.database.info(
            "Xtream phase spacing: waiting \(seconds, privacy: .public)s for the provider connection slot"
        )
        let interval = Perf.begin(.xtreamPhaseSpacing)
        defer { Perf.end(interval) }
        try await Task.sleep(for: remaining)
    }
}
