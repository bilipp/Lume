//
//  TVSyncSettingsView.swift
//  Lume
//
//  Settings ▸ Sync on tvOS, inside SettingsView's persistent detail scroll
//  view: three full-width rows (iCloud / Lume Cloud / Off), each change
//  confirmed with an alert, the active backend's read-only status and, with
//  Lume Cloud on, this device's name, the Add a Device / Devices / Recovery
//  Key drill-ins plus Leave and Delete. A drill-in replaces the pane's top
//  level in place; SettingsView owns the route, so Menu backs out onto the
//  row that opened it.
//  A child profile needs the parental PIN to get in.
//

#if os(tvOS)

    import SwiftUI

    struct TVSyncSettingsPane: View {
        /// Owned by SettingsView, which clears it on Menu or when a rail
        /// category is activated, like its other drill-ins.
        @Binding var route: TVLumeCloudRoute?
        /// SettingsView's handle on its drill-in rows, so Menu from a Lume
        /// Cloud step lands back on the row that opened it.
        let drillInFocus: FocusState<TVSettingsDrillIn?>.Binding
        /// Scrolls SettingsView's detail back to its top.
        let scrollToTop: () -> Void

        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @Environment(ParentalControls.self) private var parental: ParentalControls?

        var body: some View {
            ParentalGateView(subtitle: "Enter your PIN to change sync settings.") {
                if let coordinator {
                    TVSyncSettingsView(
                        coordinator: coordinator,
                        route: $route,
                        drillInFocus: drillInFocus,
                        scrollToTop: scrollToTop,
                        // Shown while the surface is locked means the PIN pad
                        // just gave way to it, taking the focused view along.
                        claimsFocusOnAppear: parental?.restrictedSurfacesLocked ?? false
                    )
                }
            }
        }
    }

    private struct TVSyncSettingsView: View {
        let coordinator: CloudSyncCoordinator
        @Binding var route: TVLumeCloudRoute?
        let drillInFocus: FocusState<TVSettingsDrillIn?>.Binding
        let scrollToTop: () -> Void
        let claimsFocusOnAppear: Bool

        @State private var model = SyncSettingsModel()
        @AppStorage(LumeCloudSettings.Key.recoveryKeyViewed) private var recoveryKeyViewed = false
        @FocusState private var actionFocus: Action?

        private enum Action: Hashable {
            case leave
            case deleteAccount
        }

        private var status: CloudSyncStatus {
            coordinator.status
        }

        var body: some View {
            // A real container, not a Group: `onAppear` must fire once for
            // the pane, not again each time a drill-in gives way to the top
            // level.
            VStack(alignment: .leading, spacing: 36) {
                if let route {
                    TVLumeCloudRouteDetail(route: route, onClose: close)
                } else {
                    backendSection
                    statusSection
                    if coordinator.selectedBackend == .lumecloud {
                        lumeCloudSection
                        membershipSection
                    }
                }
            }
            // Entry from the rail lands on the active backend's row.
            .defaultFocus(drillInFocus, .syncBackend(coordinator.selectedBackend), priority: .userInitiated)
            .alert(
                model.prompt.map(SyncSettingsPromptText.title) ?? Text(verbatim: ""),
                isPresented: $model.isPromptPresented,
                presenting: model.prompt
            ) { prompt in
                SyncSettingsPromptActions(prompt: prompt, model: model, coordinator: coordinator) { openAfterAlert(Self.route(for: $0)) }
            } message: { prompt in
                SyncSettingsPromptText.message(prompt, leaveTarget: coordinator.lumeCloudLeaveTarget)
            }
            .alert(
                model.alert?.title ?? "",
                isPresented: $model.isAlertPresented,
                presenting: model.alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(verbatim: alert.message)
            }
            .onChange(of: model.sheet?.id) { openRequestedFlow() }
            .onChange(of: coordinator.selectedBackend) { _, backend in
                // A switch that drops Lume Cloud's rows would keep a stale
                // offset otherwise.
                scrollToTop()
                // The Lume Cloud rows come and go with the switch; focus on
                // one of them would otherwise drop to the rail.
                guard route == nil, focusIsOnPaneRow else { return }
                moveFocus(to: .syncBackend(backend))
            }
            .task { model.deviceName = coordinator.lumeCloudDeviceName }
            .onAppear {
                guard claimsFocusOnAppear else { return }
                moveFocus(to: .syncBackend(coordinator.selectedBackend))
            }
        }

        private var focusIsOnPaneRow: Bool {
            if actionFocus != nil { return true }
            switch drillInFocus.wrappedValue {
            case .syncBackend, .lumeCloudDeviceName, .lumeCloudAddDevice, .lumeCloudDevices, .lumeCloudRecoveryKey: return true
            default: return false
            }
        }

        // MARK: - Backend choice

        private var backendSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sync With")

                ForEach(coordinator.availableBackends, id: \.self) { backend in
                    backendRow(backend)
                }

                if model.isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Working…")
                    }
                    .tvSettingsSecondaryText()
                    .padding(.top, 4)
                }
            }
        }

        private func backendRow(_ backend: SyncBackendSelection) -> some View {
            let isActive = coordinator.selectedBackend == backend
            return Button {
                model.request(backend, using: coordinator)
            } label: {
                HStack(spacing: 16) {
                    Text(SyncSettingsPromptText.name(of: backend))
                    Spacer(minLength: 0)
                    if isActive {
                        TVSwitchRowCheckmark()
                    }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .modifier(TVSwitchRowActiveState(isActive: isActive))
            .focused(drillInFocus, equals: .syncBackend(backend))
        }

        // MARK: - Status

        private var statusSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Status")

                switch coordinator.selectedBackend {
                case .icloud:
                    TVSettingsValueRow("iCloud Sync") {
                        statusValue(Text(CloudSyncStatusText.accountDescription(status.account)))
                    }
                case .lumecloud:
                    TVSettingsValueRow("Lume Cloud") {
                        statusValue(Text(CloudSyncStatusText.summary(status)))
                    }
                case .off:
                    EmptyView()
                }

                statusFootnote(CloudSyncStatusText.detail(for: status))

                if coordinator.selectedBackend != .off {
                    TVLumeCloudActionRow(
                        "Sync Now",
                        systemImage: "arrow.triangle.2.circlepath",
                        isBusy: coordinator.isSyncingNow
                    ) {
                        Task { await coordinator.syncNow() }
                    }
                    .disabled(coordinator.isSyncingNow || !coordinator.canSyncNow)
                }

                switch coordinator.selectedBackend {
                case .icloud:
                    statusFootnote(Text(CloudSyncStatusText.footer))
                case .lumecloud:
                    statusFootnote(Text(SyncSettingsPromptText.privacyNote))
                case .off:
                    EmptyView()
                }
            }
        }

        private func statusValue(_ value: Text) -> some View {
            HStack(spacing: 12) {
                if status.isSyncing {
                    ProgressView()
                }
                value
            }
        }

        private func statusFootnote(_ text: Text) -> some View {
            text
                .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 4)
        }

        // MARK: - Lume Cloud

        private var lumeCloudSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Lume Cloud")

                TVSettingsField(title: "Device Name", placeholder: "Device Name", text: $model.deviceName)
                    .focused(drillInFocus, equals: .lumeCloudDeviceName)
                    .onSubmit { model.commitDeviceName(using: coordinator) }

                drillInRow("Add a Device", systemImage: "plus.circle", opening: .addDevice)
                drillInRow("Devices", systemImage: "laptopcomputer.and.iphone", opening: .devices)
                drillInRow("Recovery Key", systemImage: "key", opening: .recoveryKey, showsBadge: !recoveryKeyViewed)
            }
        }

        private func drillInRow(
            _ title: LocalizedStringKey,
            systemImage: String,
            opening target: TVLumeCloudRoute,
            showsBadge: Bool = false
        ) -> some View {
            Button {
                route = target
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 36)
                        .accessibilityHidden(true)
                    Text(title)
                    Spacer(minLength: 0)
                    if showsBadge {
                        SyncSettingsBadge()
                    }
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .focused(drillInFocus, equals: target.opener)
        }

        private var membershipSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.requestLeave(using: coordinator)
                } label: {
                    HStack(spacing: 16) {
                        Text("Leave Lume Cloud")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
                .focused($actionFocus, equals: .leave)

                Button {
                    guard !model.isWorking else { return }
                    model.prompt = .deleteAccount
                } label: {
                    HStack(spacing: 16) {
                        Text("Delete Lume Cloud Account")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
                .focused($actionFocus, equals: .deleteAccount)
            }
        }

        // MARK: - Navigation

        /// The model asks for the iOS sheets; here each one is a drill-in.
        private func openRequestedFlow() {
            guard let sheet = model.sheet else { return }
            model.sheet = nil
            route = Self.route(for: sheet)
        }

        private static func route(for sheet: SyncSettingsModel.Sheet) -> TVLumeCloudRoute {
            switch sheet {
            case .join: .join
            case .addDevice: .addDevice
            case .restore: .restore
            case let .recoveryKey(recoveryKey): .newAccountRecoveryKey(recoveryKey)
            }
        }

        /// The dismissing alert hands focus back to the row it was opened
        /// from once its animation ends, overriding the step's own claim: with
        /// the row gone by then, focus would fall to the rail. Same wait as for
        /// a dismissing keyboard (TVRecordingServerPairingStep).
        private func openAfterAlert(_ target: TVLumeCloudRoute) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                route = target
            }
        }

        /// A step finished or was cancelled: back to the top level, onto the
        /// row that opened it.
        private func close() {
            guard let closing = route else { return }
            route = nil
            moveFocus(to: closing.opener)
        }

        /// Deferred past the render that inserts the target, which would
        /// otherwise drop the write.
        private func moveFocus(to target: TVSettingsDrillIn) {
            Task { @MainActor in drillInFocus.wrappedValue = target }
        }
    }

    extension TVLumeCloudRoute {
        /// The Sync pane row focus returns to when this step closes.
        var opener: TVSettingsDrillIn {
            switch self {
            case .join, .restore, .newAccountRecoveryKey: .syncBackend(.lumecloud)
            case .addDevice: .lumeCloudAddDevice
            case .devices: .lumeCloudDevices
            case .recoveryKey: .lumeCloudRecoveryKey
            }
        }
    }

#endif
