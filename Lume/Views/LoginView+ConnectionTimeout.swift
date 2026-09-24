//
//  LoginView+ConnectionTimeout.swift
//  Lume
//
//  Split out of LoginView.swift to keep that file under the 600-line lint cap.
//

import SwiftUI

// MARK: - Connection-test timeout

extension LoginView {
    struct ConnectionTimeoutError: LocalizedError {
        var errorDescription: String? {
            String(localized: "The connection timed out. Check the URL and your network, then try again.")
        }
    }

    /// Runs an add-playlist connection test under an overall deadline, cancelling
    /// the in-flight request and surfacing a timeout when it's exceeded.
    ///
    /// Each client has its own per-request timeout and (for Xtream) retry/backoff
    /// tuned for *sync*, where retries matter; left unbounded, a wrong URL or
    /// dead host can hang the add sheet for ~30–90s on a spinner with no way out.
    /// This caps the test (default 20s) without weakening the sync path.
    func withConnectionTimeout(_ seconds: Double = 20, _ operation: @escaping () async throws -> Void) async throws {
        let work = Task { try await operation() }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
        }
        defer { watchdog.cancel() }
        do {
            try await work.value
        } catch {
            if work.isCancelled { throw ConnectionTimeoutError() }
            throw error
        }
    }
}
