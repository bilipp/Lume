//
//  SyncSettingsView.swift
//  Lume
//
//  Settings ▸ Sync on iOS, macOS and visionOS: which backend this device syncs
//  through (iCloud, Lume Cloud or Off), each switch confirmed first, plus the
//  active backend's status and, for Lume Cloud, this device's name, the
//  account's devices, the recovery key, Leave and Delete. A child profile needs
//  the parental PIN to get in. The confirmations, their text
//  (SyncSettingsPromptText) and their model (SyncSettingsModel) are shared
//  with the tvOS pane (TVSyncSettingsView).
//

import SwiftUI

#if !os(tvOS)

    struct SyncSettingsView: View {
        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?

        var body: some View {
            ParentalGateView(subtitle: "Enter your PIN to change sync settings.") {
                if let coordinator {
                    SyncSettingsList(coordinator: coordinator)
                } else {
                    List {}
                        .platformNavigationTitle("Sync")
                }
            }
        }
    }

    private struct SyncSettingsList: View {
        let coordinator: CloudSyncCoordinator

        @State private var model = SyncSettingsModel()
        @AppStorage(LumeCloudSettings.Key.recoveryKeyViewed) private var recoveryKeyViewed = false

        private var status: CloudSyncStatus {
            coordinator.status
        }

        var body: some View {
            List {
                backendSection
                switch coordinator.selectedBackend {
                case .icloud: iCloudSection
                case .lumecloud: lumeCloudSections
                case .off: offSection
                }
            }
            .platformNavigationTitle("Sync")
            .alert(
                model.alert?.title ?? "",
                isPresented: $model.isAlertPresented,
                presenting: model.alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(verbatim: alert.message)
            }
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .join: LumeCloudPairingSheet(role: .join)
                case .addDevice: LumeCloudPairingSheet(role: .addDevice(code: nil))
                case .restore: LumeCloudRestoreSheet()
                case let .recoveryKey(recoveryKey): LumeCloudRecoveryKeyView(context: .created(recoveryKey: recoveryKey))
                }
            }
            .task { model.deviceName = coordinator.lumeCloudDeviceName }
            .onDisappear { model.commitDeviceName(using: coordinator) }
        }

        // MARK: Backend choice

        private var backendSection: some View {
            Section {
                Picker("Sync With", selection: Binding(
                    get: { coordinator.selectedBackend },
                    set: { model.request($0, using: coordinator) }
                )) {
                    ForEach(coordinator.availableBackends, id: \.self) { backend in
                        Text(SyncSettingsPromptText.name(of: backend)).tag(backend)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(model.isWorking)
                .modifier(SyncPromptDialog(model: model, coordinator: coordinator) { prompt in
                    switch prompt {
                    case .switchTo, .setUpLumeCloud: true
                    case .leave, .deleteAccount: false
                    }
                })
                if model.isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Working…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sync With")
            }
        }

        // MARK: iCloud

        private var iCloudSection: some View {
            Section {
                HStack {
                    Label("iCloud Sync", systemImage: iCloudIconName)
                    Spacer()
                    Text(CloudSyncStatusText.accountDescription(status.account))
                        .foregroundStyle(.secondary)
                }
                CloudSyncStatusText.detail(for: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SyncNowButton(coordinator: coordinator)
            } footer: {
                Text(CloudSyncStatusText.footer)
            }
        }

        private var iCloudIconName: String {
            if status.isSyncing { return "arrow.triangle.2.circlepath.icloud" }
            switch status.account {
            case .available: return "checkmark.icloud"
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable: return "xmark.icloud"
            case .unknown: return "icloud"
            }
        }

        // MARK: Lume Cloud

        @ViewBuilder
        private var lumeCloudSections: some View {
            Section {
                LabeledContent("Status") {
                    Text(CloudSyncStatusText.summary(status))
                }
                CloudSyncStatusText.detail(for: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SyncNowButton(coordinator: coordinator)
                LabeledContent("Device Name") {
                    TextField("Device Name", text: $model.deviceName, prompt: Text(verbatim: LumeCloudSettings.genericModelName))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .onSubmit { model.commitDeviceName(using: coordinator) }
                }
            } header: {
                Text("Lume Cloud")
            } footer: {
                Text(SyncSettingsPromptText.privacyNote)
            }

            Section {
                Button {
                    model.sheet = .addDevice
                } label: {
                    Label("Add a Device", systemImage: "plus.circle")
                }
                NavigationLink {
                    LumeCloudDevicesView()
                } label: {
                    Label("Devices", systemImage: "laptopcomputer.and.iphone")
                }
                NavigationLink {
                    LumeCloudRecoveryKeyView(context: .settings)
                } label: {
                    HStack {
                        Label("Recovery Key", systemImage: "key")
                        Spacer(minLength: 8)
                        if !recoveryKeyViewed {
                            SyncSettingsBadge()
                        }
                    }
                }
            }

            Section {
                Button("Leave Lume Cloud", role: .destructive) {
                    model.requestLeave(using: coordinator)
                }
                .modifier(SyncPromptDialog(model: model, coordinator: coordinator) { prompt in
                    if case .leave = prompt { true } else { false }
                })
                Button("Delete Lume Cloud Account", role: .destructive) {
                    model.prompt = .deleteAccount
                }
                .modifier(SyncPromptDialog(model: model, coordinator: coordinator) { $0 == .deleteAccount })
            }
            .disabled(model.isWorking)
        }

        // MARK: Off

        private var offSection: some View {
            Section {
                CloudSyncStatusText.detail(for: status)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The confirmation for the prompts `anchors` accepts, attached to the
    /// control that raises them so an iPad popover points at it.
    /// Runs a sync pass right away on the active backend, with a spinner while
    /// it runs. Disabled when there is nothing to reach (no iCloud account, or
    /// no Lume Cloud membership).
    private struct SyncNowButton: View {
        let coordinator: CloudSyncCoordinator

        var body: some View {
            // The button holds only the label, like the other action rows, so
            // it keeps the tint and dims when disabled; the spinner sits beside it.
            HStack {
                Button {
                    Task { await coordinator.syncNow() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(coordinator.isSyncingNow || !coordinator.canSyncNow)
                Spacer()
                if coordinator.isSyncingNow {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private struct SyncPromptDialog: ViewModifier {
        let model: SyncSettingsModel
        let coordinator: CloudSyncCoordinator
        let anchors: (SyncSettingsModel.Prompt) -> Bool

        func body(content: Content) -> some View {
            let prompt = model.prompt.flatMap { anchors($0) ? $0 : nil }
            content
                .confirmationDialog(
                    prompt.map(SyncSettingsPromptText.title) ?? Text(verbatim: ""),
                    isPresented: Binding(
                        get: { prompt != nil },
                        set: { if !$0 { model.prompt = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: prompt
                ) { prompt in
                    SyncSettingsPromptActions(prompt: prompt, model: model, coordinator: coordinator) { model.sheet = $0 }
                } message: { prompt in
                    SyncSettingsPromptText.message(prompt, leaveTarget: coordinator.lumeCloudLeaveTarget)
                }
        }
    }

#endif

/// The dot that marks a Lume Cloud recovery key nobody has looked at yet,
/// on the Recovery Key row and the root Settings ▸ Sync row.
struct SyncSettingsBadge: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .accessibilityLabel("Recovery key not viewed")
    }
}

// MARK: - Confirmations

/// The buttons of a Sync confirmation, shared with the tvOS pane. `open`
/// starts the flow a button asks for: a sheet here, a drill-in on tvOS.
struct SyncSettingsPromptActions: View {
    let prompt: SyncSettingsModel.Prompt
    let model: SyncSettingsModel
    let coordinator: CloudSyncCoordinator
    let open: (SyncSettingsModel.Sheet) -> Void

    var body: some View {
        switch prompt {
        case let .switchTo(target):
            if target == .off {
                Button("Turn Off Sync", role: .destructive) { model.switchBackend(to: target, using: coordinator) }
            } else {
                Button("Switch") { model.switchBackend(to: target, using: coordinator) }
            }
            Button("Cancel", role: .cancel) {}
        case .setUpLumeCloud:
            Button("Create New Account") { model.createAccount(using: coordinator) }
            Button("Join with a Code") { open(.join) }
            Button("Restore from Recovery Key") { open(.restore) }
            Button("Cancel", role: .cancel) {}
        case .leave:
            Button("Leave Lume Cloud", role: .destructive) { model.leave(using: coordinator) }
            Button("Cancel", role: .cancel) {}
        case .deleteAccount:
            Button("Delete Account", role: .destructive) { model.deleteAccount(using: coordinator) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
