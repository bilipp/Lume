import Foundation

/// Lume Cloud pairing, for the pairing sheet: views reach the backend only
/// through this facade.
extension CloudSyncCoordinator {
    /// Joins an account through pairing (the code goes to `onCode` to show),
    /// then makes Lume Cloud this device's backend. Cancel the calling task to
    /// stop waiting.
    func joinLumeCloud(onCode: (LumeCloudPairingCode) -> Void) async throws {
        try await lumeCloudBackend().joinWithPairingCode(onCode: onCode)
        try await switchBackend(to: .lumecloud)
    }

    /// The device waiting behind `code`, for the user to confirm.
    func lookUpLumeCloudPairing(code: String) async throws -> LumeCloudPendingDevice {
        try await lumeCloudBackend().lookUpPairing(code: code)
    }

    /// Adds the confirmed device to this device's account.
    func confirmLumeCloudPairing(_ device: LumeCloudPendingDevice) async throws {
        try await lumeCloudBackend().confirmPairing(device)
    }
}
