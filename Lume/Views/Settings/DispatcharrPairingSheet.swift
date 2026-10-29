//
//  DispatcharrPairingSheet.swift
//  Lume
//
//  Signs Lume in to a Dispatcharr server as its recording server, with an API
//  key the user generated in Dispatcharr or a username and password. Lume never
//  creates or replaces keys there.
//

#if !os(tvOS)

    import SwiftUI

    /// What a Dispatcharr sign-in sheet opens for: a new server, or the paired
    /// one to sign in to again.
    struct DispatcharrPairingTarget: Identifiable, Hashable {
        let server: RecordingServerConfig?

        static let new = DispatcharrPairingTarget(server: nil)

        var id: String {
            server?.id.uuidString ?? "new"
        }
    }

    struct DispatcharrPairingSheet: View {
        let target: DispatcharrPairingTarget

        @Environment(\.dismiss) private var dismiss
        @State private var model: DispatcharrPairingModel
        @FocusState private var focusedField: Field?

        private enum Field: Hashable {
            case address
            case apiKey
            case username
            case password
        }

        init(target: DispatcharrPairingTarget) {
            self.target = target
            _model = State(initialValue: DispatcharrPairingModel(server: target.server))
        }

        var body: some View {
            NavigationStack {
                Form {
                    addressSection
                    credentialSection
                    if let errorMessage = model.errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                    Section {
                        EmptyView()
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(RecordingServerSetup.dispatcharrDisclosure)
                            Text(RecordingServerSetup.disclaimer)
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(model.isConnecting)
                .platformNavigationTitle(target.server == nil ? "Add Dispatcharr Server" : "Sign In Again")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Connect") { connect() }
                                .disabled(!model.canConnect)
                        }
                    }
                }
                .onAppear {
                    focusedField = model.address.isEmpty ? .address : firstCredentialField
                }
            }
            .interactiveDismissDisabled(model.isConnecting)
            #if os(macOS)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 400, idealHeight: 480)
            #endif
        }

        private var firstCredentialField: Field {
            model.method == .apiKey ? .apiKey : .username
        }

        // MARK: - Sections

        private var addressSection: some View {
            Section {
                TextField(
                    "Address",
                    text: $model.address,
                    prompt: Text(verbatim: "192.168.1.20:\(DispatcharrClient.defaultPort)")
                )
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                #endif
                    .focused($focusedField, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focusedField = firstCredentialField }
                    .onChange(of: model.address) { model.inputDidChange() }
            } header: {
                Text("Server Address")
            } footer: {
                Text("The address of your Dispatcharr server. Without a port, Lume uses \(String(DispatcharrClient.defaultPort)).")
            }
        }

        private var credentialSection: some View {
            Section {
                Picker("Sign In With", selection: $model.method) {
                    Text("API Key").tag(DispatcharrPairingModel.SignInMethod.apiKey)
                    Text("Username & Password").tag(DispatcharrPairingModel.SignInMethod.login)
                }
                .onChange(of: model.method) { model.inputDidChange() }
                switch model.method {
                case .apiKey:
                    // A plain field, as in Dispatcharr's own UI: iOS reads any
                    // SecureField after the address as a login and offers to
                    // save the key to Passwords.
                    TextField("API Key", text: $model.apiKey)
                        .textContentType(.oneTimeCode)
                        .font(.body.monospaced())
                        .privacySensitive()
                        .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .focused($focusedField, equals: .apiKey)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                        .onChange(of: model.apiKey) { model.inputDidChange() }
                case .login:
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .onChange(of: model.username) { model.inputDidChange() }
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                        .onChange(of: model.password) { model.inputDidChange() }
                }
            } header: {
                Text("Sign In")
            } footer: {
                switch model.method {
                case .apiKey:
                    Text("Paste an API key you generated in Dispatcharr. Lume never creates or replaces keys.")
                case .login:
                    Text("Lume keeps your sign-in details encrypted in iCloud so your other devices can use this server too.")
                }
            }
        }

        // MARK: - Actions

        private func connect() {
            guard model.canConnect else { return }
            Task {
                if await model.connect() {
                    dismiss()
                }
            }
        }
    }

#endif
