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

/// Where Lume Cloud stands on this device. Meaningful only while Lume Cloud is
/// the active backend; iCloud keeps reporting through `CloudAccountStatus`.
nonisolated enum LumeCloudSyncState: Equatable {
    case notJoined
    case joined
    case syncing
    /// The first multi-batch upload: `completed` of `total` batches sent.
    case uploading(completed: Int, total: Int)
    /// 401 `device_revoked`: this device was removed and went Off.
    case revoked
    /// 404 `account_deleted`: the account is gone.
    case accountDeleted
    /// 429: backing off per `Retry-After`.
    case rateLimited
    /// 507: pushing stopped, pulling continues.
    case quotaExceeded
    case offline
}

/// Observable, user-facing sync status read by the settings screens.
/// Lives on the main actor; mutated only by `CloudSyncCoordinator` and the
/// active `SyncBackend`.
@MainActor
@Observable
final class CloudSyncStatus {
    /// The backend this device syncs through.
    var backend: SyncBackendSelection = .icloud

    /// Lume Cloud's state; read only while `backend == .lumecloud`.
    var lumeCloud: LumeCloudSyncState = .notJoined

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

    /// True while another Apple device's move to Lume Cloud, picked up at
    /// launch, holds the launch gate until this device's first Lume Cloud pass
    /// lands or `CloudSyncCoordinator.initialSyncTimeout` runs out.
    var isAwaitingLaunchJoin: Bool = false

    /// True while a fresh install shows the first-run sync choice (iCloud,
    /// Lume Cloud or Off). Sync stays Off until the user picks one.
    var isAwaitingBackendChoice: Bool = false

    /// Whether a fresh install may decide between the add-playlist form and
    /// the app.
    var isLaunchGateOpen: Bool {
        hasCompletedInitialSync && !isAwaitingLaunchJoin && !isAwaitingBackendChoice
    }

    /// When the local reconcile last completed successfully.
    var lastReconcile: Date?

    /// The most recent CloudKit sync error, if any (cleared on the next success).
    var lastError: String?

    /// Counters from the last reconcile, for diagnostics.
    var lastResult: CloudSyncReconcileResult?
}
