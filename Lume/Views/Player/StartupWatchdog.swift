//
//  StartupWatchdog.swift
//  Lume
//
//  The startup-failure window shared by the engines that report their own
//  startup progress (LumeEngine, AetherEngine).
//

import Foundation

enum StartupWatchdog {
    /// Fails a load that never starts. The window rolls while `progress`
    /// keeps rising (a slow origin can spend most of it buffering or
    /// analysing), so a load stuck without progress still fails within
    /// `timeout`; a hard cap of `max(3 × timeout, 60 s)` bounds the rest.
    /// `onTimeout` receives the last progress value seen.
    static func start(
        timeout: TimeInterval,
        pollInterval: Duration,
        progress: @escaping () async -> Int64,
        hasStarted: @escaping () -> Bool,
        onTimeout: @escaping (_ lastProgress: Int64) -> Void
    ) -> Task<Void, Never> {
        Task {
            let hardDeadline = Date(timeIntervalSinceNow: max(timeout * 3, 60))
            var deadline = Date(timeIntervalSinceNow: timeout)
            var lastProgress: Int64 = 0
            while !Task.isCancelled, !hasStarted() {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, !hasStarted() else { return }
                let current = await progress()
                if current > lastProgress {
                    lastProgress = current
                    deadline = min(Date(timeIntervalSinceNow: timeout), hardDeadline)
                }
                if Date() >= deadline {
                    onTimeout(lastProgress)
                    return
                }
            }
        }
    }
}
