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

    /// When the local reconcile last completed successfully.
    var lastReconcile: Date?

    /// The most recent CloudKit sync error, if any (cleared on the next success).
    var lastError: String?

    /// Counters from the last reconcile, for diagnostics.
    var lastResult: CloudSyncReconcileResult?
}
