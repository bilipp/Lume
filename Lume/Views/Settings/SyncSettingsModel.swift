import LumeCloudKit
import SwiftUI

/// Drives `SyncSettingsView` and the tvOS `TVSyncSettingsPane`: the pending
/// confirmation, the flow it opens and the coordinator call behind it.
@MainActor
@Observable
final class SyncSettingsModel {
    enum Prompt: Equatable {
        case switchTo(SyncBackendSelection)
        /// Lume Cloud has no account on this device yet.
        case setUpLumeCloud
        /// The Android devices that keep syncing without this one, by name.
        case leave(otherDeviceNames: [String])
        case deleteAccount
    }

    /// The flow a confirmation opens: a sheet, or a drill-in on tvOS.
    enum Sheet: Identifiable {
        case join
        case addDevice
        case restore
        case recoveryKey(String)

        var id: String {
            switch self {
            case .join: "join"
            case .addDevice: "addDevice"
            case .restore: "restore"
            case .recoveryKey: "recoveryKey"
            }
        }
    }

    struct Alert {
        var title: LocalizedStringKey
        var message: String
    }

    var prompt: Prompt?
    var sheet: Sheet?
    var alert: Alert?
    var deviceName = ""
    private(set) var isWorking = false

    var isPromptPresented: Bool {
        get { prompt != nil }
        set { if !newValue { prompt = nil } }
    }

    var isAlertPresented: Bool {
        get { alert != nil }
        set { if !newValue { alert = nil } }
    }

    /// The picker asked for `target`: confirm first. Leaving Lume Cloud for
    /// iCloud is a Leave; turning Lume Cloud on without an account asks how.
    func request(_ target: SyncBackendSelection, using coordinator: CloudSyncCoordinator) {
        let current = coordinator.selectedBackend
        guard target != current, !isWorking else { return }
        switch target {
        case .lumecloud:
            prompt = coordinator.hasLumeCloudAccount() ? .switchTo(.lumecloud) : .setUpLumeCloud
        case .icloud where current == .lumecloud:
            requestLeave(using: coordinator)
        case .icloud, .off:
            prompt = .switchTo(target)
        }
    }

    /// Looks up the Android devices on the account first, so the warning can
    /// name them. Unreachable, the warning goes without names.
    func requestLeave(using coordinator: CloudSyncCoordinator) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let devices = await (try? coordinator.lumeCloudDevices()) ?? []
            isWorking = false
            let android = devices.filter { [LumeCloudPlatform.android, .androidTV].contains(LumeCloudPlatform(rawValue: $0.platform.lowercased())) }
            prompt = .leave(otherDeviceNames: android.map(\.name))
        }
    }

    func switchBackend(to target: SyncBackendSelection, using coordinator: CloudSyncCoordinator) {
        run(failureTitle: "Couldn’t Switch Sync") {
            try await coordinator.switchBackend(to: target)
        }
    }

    func createAccount(using coordinator: CloudSyncCoordinator) {
        run(failureTitle: "Couldn’t Create Account") { [weak self] in
            let recoveryKey = try await coordinator.createLumeCloudAccount()
            self?.sheet = .recoveryKey(recoveryKey)
        }
    }

    func leave(using coordinator: CloudSyncCoordinator) {
        run(failureTitle: "Couldn’t Leave Lume Cloud") {
            try await coordinator.leaveLumeCloud()
        }
    }

    func deleteAccount(using coordinator: CloudSyncCoordinator) {
        run(failureTitle: "Couldn’t Delete Account") {
            try await coordinator.deleteLumeCloudAccount()
        }
    }

    /// Saves an edited device name; the server learns it while joined.
    func commitDeviceName(using coordinator: CloudSyncCoordinator) {
        guard deviceName.trimmingCharacters(in: .whitespacesAndNewlines) != coordinator.lumeCloudDeviceName else { return }
        let name = deviceName
        Task { [weak self] in
            do {
                try await coordinator.renameLumeCloudDevice(to: name)
            } catch {
                self?.alert = Alert(title: "Couldn’t Rename This Device", message: LumeCloudErrorDescription.actionMessage(for: error))
            }
            self?.deviceName = coordinator.lumeCloudDeviceName
        }
    }

    private func run(failureTitle: LocalizedStringKey, _ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                alert = Alert(title: failureTitle, message: LumeCloudErrorDescription.actionMessage(for: error))
            }
        }
    }
}
