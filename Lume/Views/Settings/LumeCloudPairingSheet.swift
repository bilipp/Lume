//
//  LumeCloudPairingSheet.swift
//  Lume
//
//  Lume Cloud pairing (PROTOCOL.md §4.5). A new device shows a six-digit code
//  and its QR (`lume://cloud/pair?code=`) and waits; a device that already
//  syncs enters or scans that code, checks the new device's name and platform,
//  and adds it. Codes are never logged.
//

import SwiftUI

/// Which side of a pairing the sheet runs.
enum LumeCloudPairingRole: Equatable {
    /// This device joins an account: shows a code and waits for another device.
    case join
    /// This device adds another one; `code` comes prefilled from a pairing QR.
    case addDevice(code: String?)
}

#if !os(tvOS)

    struct LumeCloudPairingSheet: View {
        let role: LumeCloudPairingRole

        @Environment(\.dismiss) private var dismiss
        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @State private var model = LumeCloudPairingModel()

        private var isAddingDevice: Bool {
            role != .join
        }

        var body: some View {
            NavigationStack {
                Form {
                    if isAddingDevice {
                        addDeviceSections
                    } else {
                        joinSection
                    }
                    if let errorMessage = model.errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
                .platformNavigationTitle(isAddingDevice ? "Add a Device" : "Join Lume Cloud")
                .toolbar { toolbarContent }
                .task(id: model.joinAttempt) {
                    guard !isAddingDevice else { return }
                    if await model.join(using: coordinator) {
                        dismiss()
                    }
                }
                .task {
                    if case let .addDevice(code?) = role {
                        model.prefill(code)
                        await model.lookUp(using: coordinator)
                    }
                }
            }
            .interactiveDismissDisabled(model.isWorking)
            .lumeCloudSheetFrame()
        }

        @ToolbarContentBuilder
        private var toolbarContent: some ToolbarContent {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if isAddingDevice {
                ToolbarItem(placement: .confirmationAction) {
                    if model.pendingDevice == nil {
                        Button("Next") { lookUp() }
                            .disabled(!model.canLookUp)
                    } else {
                        Button("Add") { confirm() }
                            .disabled(model.isWorking)
                    }
                }
            }
        }

        // MARK: Join

        private var joinSection: some View {
            Section {
                if let pairing = model.pairingCode {
                    VStack(spacing: 16) {
                        Text("Enter this code")
                            .font(.headline)
                        LumeCloudPairingCodeText(code: pairing.code, size: 44, tracking: 6)
                        QRCodeView(string: pairing.deepLink.absoluteString)
                            .frame(width: 180, height: 180)
                            .padding(12)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel("Pairing QR code")
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for the other device…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else if model.errorMessage == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Try Again") { model.retryJoin() }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On a device that already uses Lume Cloud, open Settings ▸ Sync ▸ Add a Device and enter this code, or scan the QR code with that device’s camera.")
                    Text(SyncSettingsPromptText.privacyNote)
                }
            }
        }

        // MARK: Add a device

        @ViewBuilder
        private var addDeviceSections: some View {
            if let device = model.pendingDevice {
                Section {
                    LabeledContent("Name", value: device.name)
                    LabeledContent("Platform", value: LumeCloudPlatformName.displayName(for: device.platform))
                } header: {
                    Text("New Device")
                } footer: {
                    Text("Only add devices you own. The new device can read everything you sync with Lume Cloud.")
                }
            } else {
                Section {
                    TextField("Pairing Code", text: $model.code, prompt: Text(verbatim: "123456"))
                        .textContentType(.oneTimeCode)
                        .font(.title3.monospacedDigit())
                        .environment(\.layoutDirection, .leftToRight)
                    #if os(iOS) || os(visionOS)
                        .keyboardType(.numberPad)
                    #endif
                        .onChange(of: model.code) { model.sanitizeCode() }
                        .onSubmit { lookUp() }
                        .disabled(model.isWorking)
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("Enter the 6-digit code shown on the new device.")
                }
            }
        }

        private func lookUp() {
            guard model.canLookUp else { return }
            Task { await model.lookUp(using: coordinator) }
        }

        private func confirm() {
            Task {
                if await model.confirm(using: coordinator) {
                    dismiss()
                }
            }
        }
    }

#endif

extension View {
    /// The macOS size of the Lume Cloud pairing and new-key sheets, which
    /// otherwise collapse; nothing elsewhere.
    func lumeCloudSheetFrame() -> some View {
        #if os(macOS)
            frame(minWidth: 420, idealWidth: 460, minHeight: 440, idealHeight: 540)
        #else
            self
        #endif
    }
}
