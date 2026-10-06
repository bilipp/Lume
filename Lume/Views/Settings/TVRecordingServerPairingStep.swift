//
//  TVRecordingServerPairingStep.swift
//  Lume
//
//  The tvOS Recording Server pane's pairing step, shown in place of the pane's
//  top level (see TVRecordingServerSettingsView).
//

#if os(tvOS)

    import LumeRecorderKit
    import SwiftUI

    /// Checks the server's identity and API version, then exchanges the
    /// six-digit code the server prints for a token. `baseURL` is `nil` for a
    /// typed address.
    struct TVRecordingServerPairingStep: View {
        let baseURL: URL?
        let onPaired: () -> Void
        let onCancel: () -> Void

        @State private var model = RecordingServerPairingModel()
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case address
            case code
            case cancel
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Pair Recording Server")

                if baseURL == nil {
                    addressInput
                }

                if let info = model.info {
                    VStack(alignment: .leading, spacing: 8) {
                        TVSettingsValueRow("Server", value: info.name)
                        TVSettingsValueRow("Version", value: info.version)
                    }
                    codeInput
                } else if model.isChecking {
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
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Button("Cancel", action: onCancel)
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .focused($focus, equals: .cancel)
                    .disabled(model.isPairing)
                    .padding(.top, 8)
            }
            .task {
                if let baseURL {
                    Task { @MainActor in focus = .cancel }
                    await check(baseURL)
                } else {
                    Task { @MainActor in focus = .address }
                }
            }
        }

        private var addressInput: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsField(title: "Server Address", placeholder: "Address", text: $model.address, contentType: .URL)
                    .keyboardType(.URL)
                    .focused($focus, equals: .address)
                    .onSubmit { connectToAddress() }
                    .onChange(of: model.address) { model.addressDidChange() }

                Text("The address of the computer running LumeRecorder. Without a port, Lume uses \(String(LumeRecorderClient.defaultPort)).")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    connectToAddress()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "network")
                            .font(.system(size: 22, weight: .medium))
                        Text("Connect")
                        Spacer(minLength: 0)
                        if model.isChecking { ProgressView() }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty || model.isChecking)
            }
        }

        private var codeInput: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsField(title: "Pairing Code", placeholder: "Pairing Code", text: $model.code, contentType: .oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .code)
                    .onSubmit {
                        if model.canPair {
                            Task { await pair() }
                        }
                    }
                    .onChange(of: model.code) { model.sanitizeCode() }

                Text("Enter the 6-digit code from the recording server. It appears in the server's log, or run `lume-recorder pair` on the server to show the current one.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    Task { await pair() }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "key")
                            .font(.system(size: 22, weight: .medium))
                        Text("Pair")
                        Spacer(minLength: 0)
                        if model.isPairing { ProgressView() }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                // Not disabled while pairing: focus would have to leave the
                // button, and reaching the sidebar tears this step down.
                .disabled(model.code.count != RecordingServerPairingModel.codeLength)
            }
        }

        private func connectToAddress() {
            Task {
                if await model.connectToAddress() {
                    focusCode()
                }
            }
        }

        private func check(_ baseURL: URL) async {
            if await model.check(baseURL) {
                focusCode()
            }
        }

        private func focusCode() {
            Task { @MainActor in
                // Submitting from the address keyboard hands focus back to
                // the field as the keyboard dismisses, after a write made
                // right away.
                if focus == nil || focus == .address {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                focus = .code
            }
        }

        private func pair() async {
            if await model.pair() {
                onPaired()
            }
        }
    }

#endif
