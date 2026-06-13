import Foundation

/// Whether the device can reach the user's iCloud account — distinct from
/// whether a sync is in flight. Maps from `CKAccountStatus`.
enum CloudAccountStatus: Equatable {
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    /// Whether sync can actually happen. Only `.available` syncs; everything
    /// else means the local store works but changes stay on-device.
    var canSync: Bool {
        self == .available
    }
}

/// Observable, user-facing iCloud sync status read by the settings screens.
/// Lives on the main actor; mutated only by `CloudSyncCoordinator`.
@MainActor
@Observable
final class CloudSyncStatus {
    /// iCloud account reachability.
    var account: CloudAccountStatus = .unknown

    /// True while CloudKit is importing or exporting (driven by
    /// `NSPersistentCloudKitContainer` events).
    var isSyncing: Bool = false

    /// Whether the launch-time iCloud sync has settled — the first CloudKit
    /// import finished, the account turned out unusable, or we gave up waiting.
    /// A fresh install (empty local store) gates the add-playlist form on this,
    /// so cloud playlists get a chance to arrive before the form is offered,
    /// instead of it flashing up and then vanishing mid-typing. Set by
    /// `CloudSyncCoordinator` (immediately when CloudKit is disabled).
    var hasCompletedInitialSync: Bool = false

    /// When the local reconcile last completed successfully.
    var lastReconcile: Date?

    /// The most recent CloudKit sync error, if any (cleared on the next success).
    var lastError: String?

    /// Counters from the last reconcile, for diagnostics.
    var lastResult: CloudSyncReconcileResult?
}
