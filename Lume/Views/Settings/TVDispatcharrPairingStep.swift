//
//  TVDispatcharrPairingStep.swift
//  Lume
//
//  The tvOS Recording Server pane's Dispatcharr sign-in step, shown in place
//  of the pane's top level (see TVRecordingServerSettingsView). Signs in with
//  an API key the user generated in Dispatcharr or a username and password;
//  Lume never creates or replaces keys there.
//

#if os(tvOS)

    import SwiftUI

    struct TVDispatcharrPairingStep: View {
        /// The paired server to sign in to again; `nil` adds a new one.
        let server: RecordingServerConfig?
        let onPaired: () -> Void
        let onCancel: () -> Void

        @State private var model: DispatcharrPairingModel
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case address
            case method
            case apiKey
            case username
            case password
            case connect
            case cancel
        }

        init(server: RecordingServerConfig?, onPaired: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.server = server
            self.onPaired = onPaired
            self.onCancel = onCancel
            _model = State(initialValue: DispatcharrPairingModel(server: server))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel(server == nil ? "Add Dispatcharr Server" : "Sign In Again")

                addressInput
                methodRow
                credentialInput
                connectRow

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Button("Cancel", action: onCancel)
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .focused($focus, equals: .cancel)
                    .disabled(model.isConnecting)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text(RecordingServerSetup.dispatcharrDisclosure)
                    Text(RecordingServerSetup.disclaimer)
                }
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 8)
            }
            .task {
                Task { @MainActor in focus = model.address.isEmpty ? .address : firstCredentialField }
            }
        }

        private var firstCredentialField: Field {
            model.method == .apiKey ? .apiKey : .username
        }

        // MARK: - Inputs

        private var addressInput: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsField(title: "Server Address", placeholder: "Address", text: $model.address, contentType: .URL)
                    .keyboardType(.URL)
                    .focused($focus, equals: .address)
                    .onSubmit { handOff(to: firstCredentialField) }
                    .onChange(of: model.address) { model.inputDidChange() }

                Text("The address of your Dispatcharr server. Without a port, Lume uses \(String(DispatcharrClient.defaultPort)).")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }
            .disabled(model.isConnecting)
        }

        private var methodRow: some View {
            TVOptionCycleRow(title: "Sign In With", valueLabel: methodLabel) {
                model.method = model.method == .apiKey ? .login : .apiKey
                model.inputDidChange()
            }
            .focused($focus, equals: .method)
            .disabled(model.isConnecting)
        }

        private var methodLabel: String {
            switch model.method {
            case .apiKey: String(localized: "API Key")
            case .login: String(localized: "Username & Password")
            }
        }

        private var credentialInput: some View {
            VStack(alignment: .leading, spacing: 16) {
                switch model.method {
                case .apiKey:
                    // Not a password: keeps the system from offering to save it.
                    TVSettingsField(
                        title: "API Key",
                        placeholder: "API Key",
                        text: $model.apiKey,
                        isSecure: true,
                        contentType: .oneTimeCode
                    )
                    .focused($focus, equals: .apiKey)
                    .onSubmit { submitLastField() }
                    .onChange(of: model.apiKey) { model.inputDidChange() }

                    Text("Enter an API key you generated in Dispatcharr. You can type it with your iPhone's keyboard. Lume never creates or replaces keys.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                case .login:
                    TVSettingsField(title: "Username", placeholder: "Username", text: $model.username, contentType: .username)
                        .focused($focus, equals: .username)
                        .onSubmit { handOff(to: .password) }
                        .onChange(of: model.username) { model.inputDidChange() }

                    TVSettingsField(
                        title: "Password",
                        placeholder: "Password",
                        text: $model.password,
                        isSecure: true,
                        contentType: .password
                    )
                    .focused($focus, equals: .password)
                    .onSubmit { submitLastField() }
                    .onChange(of: model.password) { model.inputDidChange() }

                    Text("Lume keeps your sign-in details encrypted in iCloud so your other devices can use this server too.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
            .disabled(model.isConnecting)
        }

        /// Not disabled while connecting: focus would have to leave the row
        /// mid-sign-in, and a failure leaves it on Connect.
        private var connectRow: some View {
            TVSettingsActionRow("Connect", systemImage: "network", isBusy: model.isConnecting) {
                connect()
            }
            .focused($focus, equals: .connect)
            .disabled(!model.hasInput)
        }

        // MARK: - Actions

        /// Submitting from the keyboard hands focus back to the field as the
        /// keyboard dismisses, after a write made right away.
        private func handOff(to target: Field) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                focus = target
            }
        }

        /// Connects only once focus is on Connect: connecting disables the
        /// fields, and a field disabled while the keyboard dismisses keeps focus.
        private func submitLastField() {
            guard model.hasInput else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                focus = .connect
                connect()
            }
        }

        private func connect() {
            guard model.canConnect else { return }
            Task {
                if await model.connect() {
                    onPaired()
                }
            }
        }
    }

#endif
