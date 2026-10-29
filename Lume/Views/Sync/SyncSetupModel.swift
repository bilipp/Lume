import SwiftUI

/// Drives the first-run sync choice (`SyncSetupView`): the backend picked,
/// the Lume Cloud step, the account flow it opens and the coordinator call
/// behind each. The choice ends once a backend is committed, or once a Lume
/// Cloud flow switched this device to Lume Cloud and closed.
@MainActor
@Observable
final class SyncSetupModel {
    /// A Lume Cloud flow: a sheet here, a step in place on tvOS.
    enum Flow: Hashable, Identifiable {
        case join
        case restore
        /// The key of the account just created. Never log it.
        case recoveryKey(String)

        var id: String {
            switch self {
            case .join: "join"
            case .restore: "restore"
            case .recoveryKey: "recoveryKey"
            }
        }
    }

    var selection: SyncBackendSelection
    /// The Lume Cloud step (create, join or restore) is showing.
    var showsLumeCloud = false
    var flow: Flow?
    var alert: SyncSettingsModel.Alert?
    private(set) var isWorking = false

    var isAlertPresented: Bool {
        get { alert != nil }
        set { if !newValue { alert = nil } }
    }

    init(selection: SyncBackendSelection) {
        self.selection = selection
    }

    /// Commits `selection`: iCloud and Off end the choice, Lume Cloud opens its step.
    func commit(using coordinator: CloudSyncCoordinator) {
        guard selection != .lumecloud else {
            showsLumeCloud = true
            return
        }
        let target = selection
        run(failureTitle: "Couldn’t Switch Sync") {
            try await coordinator.chooseInitialBackend(target)
        }
    }

    func createAccount(using coordinator: CloudSyncCoordinator) {
        run(failureTitle: "Couldn’t Create Account") { [weak self] in
            let recoveryKey = try await coordinator.createLumeCloudAccount()
            self?.flow = .recoveryKey(recoveryKey)
        }
    }

    /// Joins the account the user's other Apple devices sync with; no code needed.
    func joinOfferedAccount(using coordinator: CloudSyncCoordinator) {
        run(failureTitle: "Couldn’t Join Lume Cloud") {
            try await coordinator.joinOfferedLumeCloudAccount()
            coordinator.finishBackendChoice()
        }
    }

    /// A flow closed. Once it switched this device to Lume Cloud the choice is
    /// made; a cancelled one leaves the Lume Cloud step up.
    func flowDidClose(using coordinator: CloudSyncCoordinator) {
        flow = nil
        guard coordinator.selectedBackend == .lumecloud else { return }
        coordinator.finishBackendChoice()
    }

    /// The backend changed under the setup: a flow left early (Menu during a
    /// restore on tvOS) that still switched this device to Lume Cloud ends the
    /// choice. A running call or an open flow ends it itself.
    func backendDidChange(using coordinator: CloudSyncCoordinator) {
        guard flow == nil, !isWorking, coordinator.selectedBackend == .lumecloud else { return }
        coordinator.finishBackendChoice()
    }

    private func run(failureTitle: LocalizedStringKey, _ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                alert = SyncSettingsModel.Alert(title: failureTitle, message: LumeCloudErrorDescription.actionMessage(for: error))
            }
        }
    }
}
