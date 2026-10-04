//
//  RecordingServerPairingSheet.swift
//  Lume
//
//  Pairs Lume with a LumeRecorder server: confirms the address answers as a
//  server this build can talk to, then exchanges the one-time code the server
//  prints for a token, stored as the synced pairing.
//

#if !os(tvOS)

    import LumeRecorderKit
    import SwiftUI

    /// The server a pairing sheet opens for: a discovered (or previously
    /// paired) server, or `manual` for a typed address.
    struct RecordingServerPairingTarget: Identifiable, Hashable {
        let baseURL: URL?

        static let manual = RecordingServerPairingTarget(baseURL: nil)

        var id: String {
            baseURL?.absoluteString ?? "manual"
        }
    }

    /// Checks the server's identity and API version, then exchanges the
    /// six-digit code the server prints for a token.
    struct RecordingServerPairingSheet: View {
        let target: RecordingServerPairingTarget

        @Environment(\.dismiss) private var dismiss
        @State private var model = RecordingServerPairingModel()

        var body: some View {
            NavigationStack {
                Form {
                    if target.baseURL == nil {
                        addressSection
                    }
                    if let info = model.info {
                        serverSection(info)
                        codeSection
                    } else if model.isChecking {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Connecting…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let errorMessage = model.errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
                .platformNavigationTitle("Pair Recording Server")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Pair") {
                            Task { await pair() }
                        }
                        .disabled(!model.canPair)
                    }
                }
                .task {
                    if let baseURL = target.baseURL {
                        await model.check(baseURL)
                    }
                }
            }
            .interactiveDismissDisabled(model.isPairing)
            #if os(macOS)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 440)
            #endif
        }

        private var addressSection: some View {
            Section {
                TextField("Address", text: $model.address, prompt: Text(verbatim: "192.168.1.20:\(LumeRecorderClient.defaultPort)"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                #endif
                    .onSubmit { connectToAddress() }
                    .onChange(of: model.address) { model.addressDidChange() }
                Button("Connect") { connectToAddress() }
                    .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty || model.isChecking)
            } header: {
                Text("Server Address")
            } footer: {
                Text("The address of the computer running LumeRecorder. Without a port, Lume uses \(String(LumeRecorderClient.defaultPort)).")
            }
        }

        private func serverSection(_ info: ServerInfo) -> some View {
            Section {
                LabeledContent("Server", value: info.name)
                LabeledContent("Version", value: info.version)
            }
        }

        private var codeSection: some View {
            Section {
                TextField("Pairing Code", text: $model.code, prompt: Text(verbatim: "123456"))
                    .textContentType(.oneTimeCode)
                    .font(.title3.monospacedDigit())
                #if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
                #endif
                    .onChange(of: model.code) { model.sanitizeCode() }
                    .onSubmit {
                        if model.canPair {
                            Task { await pair() }
                        }
                    }
            } header: {
                Text("Pairing Code")
            } footer: {
                Text("Enter the 6-digit code from the recording server. It appears in the server's log, or run `lume-recorder pair` on the server to show the current one.")
            }
        }

        private func connectToAddress() {
            Task { await model.connectToAddress() }
        }

        private func pair() async {
            if await model.pair() {
                dismiss()
            }
        }
    }

#endif
