//
//  TVLumeCloudPairingSteps.swift
//  Lume
//
//  The tvOS Sync pane's Lume Cloud drill-ins, shown in place of the pane's top
//  level inside the detail column's persistent scroll view: a push would hide
//  the tab bar and strand remote focus. Each step takes focus with a deferred
//  `@FocusState` write; Menu is left to SettingsView, which puts focus back on
//  the row that opened the step. Codes are never logged.
//

#if os(tvOS)

    import SwiftUI

    /// Where the Sync pane is drilled in to; `nil` is its top level.
    enum TVLumeCloudRoute: Hashable {
        /// This device shows a code and waits for a device already in the account.
        case join
        /// This device adds another one by its code.
        case addDevice
        case devices
        /// Joins the account a typed recovery key belongs to.
        case restore
        /// The joined account's recovery key, from Settings ▸ Sync.
        case recoveryKey
        /// The key of the account just created, offered with "I've saved it"
        /// and "Later". Never log it.
        case newAccountRecoveryKey(String)
    }

    /// The step `route` names. `onClose` returns to the pane's top level.
    struct TVLumeCloudRouteDetail: View {
        let route: TVLumeCloudRoute
        let onClose: () -> Void

        var body: some View {
            switch route {
            case .join:
                TVLumeCloudJoinStep(onClose: onClose)
            case .addDevice:
                TVLumeCloudAddDeviceStep(onAdded: onClose)
            case .devices:
                TVLumeCloudDevicesStep()
            case .restore:
                TVLumeCloudRestoreStep(onRestored: onClose)
            case .recoveryKey:
                TVLumeCloudRecoveryKeyStep(newAccountKey: nil, onClose: onClose)
            case let .newAccountRecoveryKey(recoveryKey):
                TVLumeCloudRecoveryKeyStep(newAccountKey: recoveryKey, onClose: onClose)
            }
        }
    }

    // MARK: - Join

    /// Shows a code and its QR while the backend polls for the sealed grant.
    /// Cancel is the only focusable control while the code is up; leaving the
    /// step cancels the wait.
    struct TVLumeCloudJoinStep: View {
        let onClose: () -> Void

        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @State private var model = LumeCloudPairingModel()
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case retry
            case cancel
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Join Lume Cloud")

                if let pairing = model.pairingCode {
                    HStack(alignment: .center, spacing: 40) {
                        QRCodeView(string: pairing.deepLink.absoluteString)
                            .tvLumeCloudQRCard()
                            .accessibilityLabel("Pairing QR code")

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Enter this code")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                            LumeCloudPairingCodeText(code: pairing.code, size: 56, tracking: 8)
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Waiting for the other device…")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 22))
                        }
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                } else if model.errorMessage == nil {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .tvLumeCloudFootnote(isError: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("On a device that already uses Lume Cloud, open Settings ▸ Sync ▸ Add a Device and enter this code, or scan the QR code with that device’s camera.")
                    Text(SyncSettingsPromptText.privacyNote)
                }
                .tvLumeCloudFootnote()

                if model.pairingCode == nil, model.errorMessage != nil {
                    TVLumeCloudActionRow("Try Again", systemImage: "arrow.clockwise") {
                        model.retryJoin()
                        Task { @MainActor in focus = .cancel }
                    }
                    .focused($focus, equals: .retry)
                }

                Button("Cancel", action: onClose)
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .focused($focus, equals: .cancel)
                    .padding(.top, 8)
            }
            .task(id: model.joinAttempt) {
                if await model.join(using: coordinator) {
                    onClose()
                }
            }
            .onAppear {
                Task { @MainActor in focus = .cancel }
            }
        }
    }

    // MARK: - Add a device

    /// Looks up the device behind a typed code, then adds it once the user
    /// confirms its name in an alert.
    struct TVLumeCloudAddDeviceStep: View {
        let onAdded: () -> Void

        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @State private var model = LumeCloudPairingModel()
        @State private var confirmsDevice = false
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case code
            case pair
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Add a Device")

                TVSettingsField(title: "Pairing Code", placeholder: "Pairing Code", text: $model.code, contentType: .oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .code)
                    .onChange(of: model.code) { model.sanitizeCode() }
                    .onSubmit(pair)

                Text("Enter the 6-digit code shown on the new device.")
                    .tvLumeCloudFootnote()

                // Never disabled: focus would have to leave the row while the
                // code is incomplete or the lookup runs. `pair()` ignores those.
                TVLumeCloudActionRow("Pair", systemImage: "key", isBusy: model.isWorking, action: pair)
                    .focused($focus, equals: .pair)

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .tvLumeCloudFootnote(isError: true)
                }

                Text(SyncSettingsPromptText.privacyNote)
                    .tvLumeCloudFootnote()
                    .padding(.top, 8)
            }
            .alert(confirmationTitle, isPresented: $confirmsDevice, presenting: model.pendingDevice) { _ in
                Button("Add", action: confirm)
                Button("Cancel", role: .cancel) { model.discardPendingDevice() }
            } message: { device in
                Text(verbatim: LumeCloudPlatformName.displayName(for: device.platform) + "\n\n")
                    + Text("Only add devices you own. The new device can read everything you sync with Lume Cloud.")
            }
            .onAppear {
                Task { @MainActor in focus = .code }
            }
        }

        private var confirmationTitle: Text {
            guard let name = model.pendingDevice?.name else { return Text(verbatim: "") }
            return Text("Add “\(name)”?")
        }

        private func pair() {
            guard !model.isWorking else { return }
            if model.pendingDevice != nil {
                confirmsDevice = true
                return
            }
            guard model.canLookUp else {
                Task { @MainActor in focus = .code }
                return
            }
            Task {
                await model.lookUp(using: coordinator)
                if model.pendingDevice != nil {
                    confirmsDevice = true
                } else if model.code.isEmpty {
                    focus = .code
                }
            }
        }

        private func confirm() {
            Task {
                if await model.confirm(using: coordinator) {
                    onAdded()
                }
            }
        }
    }

#endif
