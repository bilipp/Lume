import Foundation

/// A fresh Apple device that follows another one into Lume Cloud at launch
/// waits for its first Lume Cloud pull before deciding between the
/// add-playlist form and the app, as the iCloud launch gate does for CloudKit.
extension CloudSyncCoordinator {
    /// Holds the launch gate for an auto-join into Lume Cloud. Holds only while
    /// the gate is still closed: a form already on screen is never taken back.
    /// The hold ends when the first Lume Cloud pass finishes, when `limit` runs
    /// out, or through `endLaunchJoinWait(openingGate:)`.
    func beginLaunchJoinWait(limit: Duration = initialSyncTimeout) {
        guard !status.hasCompletedInitialSync, !status.isAwaitingLaunchJoin else { return }
        status.isAwaitingLaunchJoin = true
        launchJoinWaitTask = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.endLaunchJoinWait(openingGate: true)
        }
    }

    /// Releases the hold. `openingGate` also opens the launch gate: the pull
    /// landed or the wait ran out. A failed join leaves the gate to the backend
    /// the device stayed on.
    func endLaunchJoinWait(openingGate: Bool) {
        guard status.isAwaitingLaunchJoin else { return }
        launchJoinWaitTask?.cancel()
        launchJoinWaitTask = nil
        status.isAwaitingLaunchJoin = false
        if openingGate {
            status.hasCompletedInitialSync = true
        }
    }
}
