import SwiftUI

/// Drives `LumeCloudRestoreSheet` and the tvOS restore step: joins the account
/// a recovery key belongs to, then makes Lume Cloud this device's backend.
@MainActor
@Observable
final class LumeCloudRestoreModel {
    var recoveryKey = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    var hasRecoveryKey: Bool {
        !recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRestore: Bool {
        hasRecoveryKey && !isWorking
    }

    /// `true` once this device restored; `false` on failure, with
    /// `errorMessage` set.
    func restore(using coordinator: CloudSyncCoordinator?) async -> Bool {
        guard canRestore else { return false }
        guard let coordinator else {
            errorMessage = LumeCloudErrorDescription.message(for: LumeCloudAccountError.unavailable)
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await coordinator.restoreLumeCloud(recoveryKey: recoveryKey)
            return true
        } catch {
            errorMessage = LumeCloudErrorDescription.message(for: error)
            return false
        }
    }
}
