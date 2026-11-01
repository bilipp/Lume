//
//  EngineFailurePolicy.swift
//  Lume
//
//  How a host answers each failure cause an engine reports: whether a drop is
//  worth reconnecting, at what pace and through which URL, and whether a
//  startup failure goes to the next engine. The engines only classify; the
//  views apply the answer.
//

import Foundation
import OSLog

nonisolated protocol EngineFailurePolicy: Equatable {
    /// The stream is gone; retrying won't bring it back.
    static var notFound: Self { get }
    /// The provider refused the URL.
    static var unauthorized: Self { get }
    /// A full connection slot or an overloaded panel.
    static var overloaded: Self { get }
}

extension EngineFailurePolicy {
    /// A dropped stream that is gone for good: retrying won't bring it back.
    var givesUpWithoutReconnect: Bool {
        self == .notFound
    }

    /// The provider refused the URL; a reconnect asks the host for a fresh one.
    var reconnectsThroughFreshURL: Bool {
        self == .unauthorized
    }

    var reconnectPace: PlaybackRetryController.Pace {
        self == .overloaded ? .overloaded : .normal
    }

    /// Whether a failure before the first frame goes to the next engine.
    /// A missing stream doesn't: every engine would ask for the same one.
    func fallsBackToNextEngine(reportsStartupFailure: Bool, hasStartedPlayback: Bool) -> Bool {
        reportsStartupFailure && !hasStartedPlayback && self != .notFound
    }
}

extension EngineFailurePolicy where Self: RawRepresentable, RawValue == String {
    /// Logs a failure before the first frame and answers whether it goes to
    /// the next engine (`true`) or to the host's failure overlay (`false`).
    func handsOffStartupFailure(engine: String, reportsStartupFailure: Bool, hasStartedPlayback: Bool) -> Bool {
        let fallsBack = fallsBackToNextEngine(
            reportsStartupFailure: reportsStartupFailure,
            hasStartedPlayback: hasStartedPlayback
        )
        let cause = rawValue
        Logger.player.error("\(engine, privacy: .public) startup failure (\(cause, privacy: .public)) → \(fallsBack ? "falling back to next engine" : "failure overlay", privacy: .public)")
        return fallsBack
    }
}

extension PlaybackRetryController {
    /// Mid-stream drop: bounded backoff, then give up loudly. A missing stream
    /// gives up at once, a refused one reconnects through `refreshStreamURL`,
    /// and an overloaded source gets the slower schedule. `reload` takes the
    /// replacement URL, `nil` to reload the current one; `holdURLRefresh`
    /// receives the task awaiting a fresh URL so the host can cancel it.
    /// Returns whether the host should raise its failure overlay.
    func reconnect(
        after failure: some EngineFailurePolicy & RawRepresentable<String>,
        engine: String,
        refreshStreamURL: (() async -> URL?)?,
        holdURLRefresh: @escaping (Task<Void, Never>) -> Void,
        reload: @escaping (URL?) -> Void
    ) -> Bool {
        guard !failure.givesUpWithoutReconnect else {
            Logger.player.error("\(engine, privacy: .public) stream not found → failure overlay, no reconnect")
            cancel()
            return true
        }
        if !hasGivenUp {
            let cause = failure.rawValue
            Logger.player.warning("\(engine, privacy: .public) dropped (\(cause, privacy: .public)) → scheduling engine reload")
            scheduleRetry(pace: failure.reconnectPace) {
                guard failure.reconnectsThroughFreshURL, let refreshStreamURL else {
                    reload(nil)
                    return
                }
                holdURLRefresh(Task {
                    let url = await refreshStreamURL()
                    guard !Task.isCancelled else { return }
                    reload(url)
                })
            }
        }
        // Checked after scheduling too: the attempt that spends the budget only
        // marks it spent, and a failed session sends nothing further.
        if hasGivenUp {
            Logger.player.error("\(engine, privacy: .public) reconnects exhausted → failure overlay")
            return true
        }
        return false
    }
}
