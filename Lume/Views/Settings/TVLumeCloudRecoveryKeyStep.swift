//
//  TVLumeCloudRecoveryKeyStep.swift
//  Lume
//
//  The tvOS Sync pane's recovery key, shown in place (see
//  TVLumeCloudPairingSteps). The key and its QR appear only after the user
//  confirms that it will be visible on the TV. Also the restore step, which
//  joins the account a typed recovery key belongs to. The key is never logged.
//

#if os(tvOS)

    import SwiftUI

    struct TVLumeCloudRecoveryKeyStep: View {
        /// The key of the account just created; `nil` reads the joined
        /// account's key from the coordinator.
        let newAccountKey: String?
        let onClose: () -> Void

        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @State private var recoveryKey: String?
        @State private var confirmsReveal = false
        @State private var errorMessage: String?
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case reveal
            case done
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Recovery Key")

                if let recoveryKey {
                    HStack(alignment: .center, spacing: 40) {
                        QRCodeView(string: recoveryKey)
                            .tvLumeCloudQRCard()
                            .accessibilityLabel("Recovery key QR code")
                            .privacySensitive()

                        TVLumeCloudRecoveryKeyText(recoveryKey: recoveryKey)
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("If you lose all your devices, this key is the only way back to your Lume Cloud data. Without it, your synced data is gone.")
                    Text("Store it somewhere safe, like a password manager. Never share it.")
                }
                .tvLumeCloudFootnote()

                if let errorMessage {
                    Text(errorMessage)
                        .tvLumeCloudFootnote(isError: true)
                }

                actions
                    .padding(.top, 8)
            }
            .alert("Show Recovery Key?", isPresented: $confirmsReveal) {
                Button("Show", action: reveal)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will be visible on your TV. Make sure no one else can see the screen.")
            }
            .onAppear {
                Task { @MainActor in
                    focus = .reveal
                    confirmsReveal = true
                }
            }
        }

        @ViewBuilder
        private var actions: some View {
            if recoveryKey == nil {
                TVLumeCloudActionRow("Show Recovery Key", systemImage: "eye") {
                    confirmsReveal = true
                }
                .focused($focus, equals: .reveal)
            } else if newAccountKey != nil {
                VStack(alignment: .leading, spacing: 8) {
                    TVLumeCloudActionRow("I’ve saved it", systemImage: "checkmark.circle") {
                        coordinator?.markLumeCloudRecoveryKeyViewed()
                        onClose()
                    }
                    .focused($focus, equals: .done)

                    TVLumeCloudActionRow("Later", systemImage: "clock", action: onClose)

                    Text("You can find this key later in Settings ▸ Sync.")
                        .tvLumeCloudFootnote()
                        .padding(.top, 8)
                }
            } else {
                TVLumeCloudActionRow("Done", systemImage: "checkmark", action: onClose)
                    .focused($focus, equals: .done)
            }
        }

        /// A new account's key counts as viewed only on "I've saved it"; the
        /// joined account's key counts as soon as it is on screen.
        private func reveal() {
            errorMessage = nil
            if let newAccountKey {
                recoveryKey = newAccountKey
            } else {
                do {
                    guard let coordinator else { throw LumeCloudAccountError.unavailable }
                    recoveryKey = try coordinator.revealLumeCloudRecoveryKey()
                } catch {
                    errorMessage = LumeCloudErrorDescription.message(for: error)
                }
            }
            if recoveryKey != nil {
                Task { @MainActor in focus = .done }
            }
        }
    }

    // MARK: - Restore

    /// Joins the Lume Cloud account a recovery key belongs to, then makes Lume
    /// Cloud this device's backend.
    struct TVLumeCloudRestoreStep: View {
        let onRestored: () -> Void

        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @State private var model = LumeCloudRestoreModel()
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case recoveryKey
            case restore
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Restore from Recovery Key")

                TVSettingsField(title: "Recovery Key", placeholder: "Recovery Key", text: $model.recoveryKey)
                    .privacySensitive()
                    .focused($focus, equals: .recoveryKey)
                    .onSubmit(restore)

                Text("Enter the recovery key you saved when you created your Lume Cloud account.")
                    .tvLumeCloudFootnote()

                // Never disabled: focus would have to leave the row while the
                // key is empty or the restore runs. `restore()` ignores those.
                TVLumeCloudActionRow("Restore", systemImage: "key", isBusy: model.isWorking, action: restore)
                    .focused($focus, equals: .restore)

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .tvLumeCloudFootnote(isError: true)
                }

                Text(SyncSettingsPromptText.privacyNote)
                    .tvLumeCloudFootnote()
                    .padding(.top, 8)
            }
            .onAppear {
                Task { @MainActor in focus = .recoveryKey }
            }
        }

        private func restore() {
            guard !model.isWorking else { return }
            guard model.hasRecoveryKey else {
                Task { @MainActor in focus = .recoveryKey }
                return
            }
            Task {
                if await model.restore(using: coordinator) {
                    onRestored()
                }
            }
        }
    }

    /// The recovery key at TV reading size: left to right in every locale and
    /// spelled out by VoiceOver.
    private struct TVLumeCloudRecoveryKeyText: View {
        let recoveryKey: String

        var body: some View {
            Text(verbatim: recoveryKey)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.layoutDirection, .leftToRight)
                .privacySensitive()
                .accessibilityLabel(
                    Text(verbatim: recoveryKey.replacingOccurrences(of: "-", with: ", "))
                        .speechSpellsOutCharacters()
                )
        }
    }

#endif
