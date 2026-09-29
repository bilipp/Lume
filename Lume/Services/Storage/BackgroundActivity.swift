//
//  BackgroundActivity.swift
//  Lume
//
//  Asks the system for time to finish store writes after the app leaves the
//  foreground.
//
//  A playlist sync, a guide refresh or an iCloud reconcile that is still saving
//  when the user switches away would otherwise be suspended mid-write. The
//  assertion lets it finish, which also means the sync gets its completion
//  stamp instead of re-running at the next launch. When the time runs out the
//  assertion is released and the work pauses with the app; that is safe now the
//  stores live outside the app-group container (see `StoreRelocation`).
//

import Foundation
#if canImport(UIKit)
    import UIKit
#endif

enum BackgroundActivity {
    /// Runs `body` under a background-task assertion named `name`. macOS has no
    /// suspension to guard against, so there it just runs `body`.
    static func perform<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        #if canImport(UIKit)
            let assertion = BackgroundAssertion(name: name)
            defer { assertion.end() }
        #endif
        return try await body()
    }
}

#if canImport(UIKit)
    private final class BackgroundAssertion {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        init(name: String) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                // Out of time: release now, or the system terminates the app.
                MainActor.assumeIsolated { self?.end() }
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
#endif
