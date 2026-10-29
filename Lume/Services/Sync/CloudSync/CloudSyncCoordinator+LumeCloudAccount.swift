import Foundation

/// Lume Cloud devices and recovery key, for the Sync settings: views reach the
/// backend only through this facade.
extension CloudSyncCoordinator {
    /// The account's devices that still sync, this device first.
    func lumeCloudDevices() async throws -> [LumeCloudDeviceInfo] {
        try await lumeCloudBackend().devices()
    }

    /// Removes another device from the account. This device leaves instead.
    func revokeLumeCloudDevice(id: UUID) async throws {
        try await lumeCloudBackend().revokeDevice(id: id)
    }

    /// Clears the "recovery key not viewed" badge on Settings ▸ Sync.
    func markLumeCloudRecoveryKeyViewed() {
        try? lumeCloudBackend().markRecoveryKeyViewed()
    }

    /// The joined account's recovery key, for showing on screen: reading it
    /// clears the "not viewed" badge. Never log it.
    func revealLumeCloudRecoveryKey() throws -> String {
        let recoveryKey = try lumeCloudBackend().recoveryKey()
        markLumeCloudRecoveryKeyViewed()
        return recoveryKey
    }

    /// Joins the account `recoveryKey` belongs to, then makes Lume Cloud this
    /// device's backend.
    func restoreLumeCloud(recoveryKey: String) async throws {
        try await lumeCloudBackend().restore(recoveryKey: recoveryKey)
        try await switchBackend(to: .lumecloud)
    }
}
