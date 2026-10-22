import Foundation
import SwiftData

/// Sync turned off on this device: no mirror, no remote, never reconciles.
/// Local data stays where it is.
@MainActor
final class OffBackend: SyncBackend {
    let kind: SyncBackendKind? = nil
    let mirrorContainer: ModelContainer? = nil
    let waitsForInitialSync = false
    let hasPendingChanges = false

    func attach(to _: any SyncBackendHost) {}
    func start() async {}
    func refreshStatus() async {}

    func pull() async throws {}
    func push() async throws {}
    func stop() {}
}
