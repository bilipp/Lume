import Foundation

/// Lume Cloud membership for the Sync settings: turning it on with a new
/// account, leaving, deleting the account and naming this device. Views reach
/// the backend only through this facade.
extension CloudSyncCoordinator {
    /// Whether this device holds a usable Lume Cloud account, so switching to
    /// Lume Cloud needs no create-or-join step. Opens the Lume Cloud store on
    /// first use; call it from actions, not from a view body.
    func hasLumeCloudAccount() -> Bool {
        (try? lumeCloudBackend())?.isJoined ?? false
    }

    /// Where leaving Lume Cloud takes this device: iCloud, or Off where this
    /// build has no iCloud.
    var lumeCloudLeaveTarget: SyncBackendSelection {
        isICloudAvailable ? .icloud : .off
    }

    /// Creates an account, makes Lume Cloud this device's backend and returns
    /// the recovery key to show. Never log it.
    func createLumeCloudAccount() async throws -> String {
        let recoveryKey = try await lumeCloudBackend().createAccount()
        try await switchBackend(to: .lumecloud)
        return recoveryKey
    }

    /// Leaves Lume Cloud on this device: switches to `lumeCloudLeaveTarget`,
    /// then removes this device from the account's device list (best effort).
    /// The account, its data and the keychain identity stay.
    func leaveLumeCloud() async throws {
        try await switchBackend(to: lumeCloudLeaveTarget)
        await (try? lumeCloudBackend())?.leave()
    }

    /// Deletes the account on the server, then switches to
    /// `lumeCloudLeaveTarget`. Throws, without switching, when the server can't
    /// be reached: a deletion is never queued. Local data stays.
    func deleteLumeCloudAccount() async throws {
        try await lumeCloudBackend().deleteAccount()
        try await switchBackend(to: lumeCloudLeaveTarget)
    }

    /// The name this device shows in the account's device list.
    var lumeCloudDeviceName: String {
        settings.deviceName
    }

    /// Renames this device locally and, while joined, on the server.
    func renameLumeCloudDevice(to name: String) async throws {
        try await lumeCloudBackend().renameDevice(to: name)
    }
}
