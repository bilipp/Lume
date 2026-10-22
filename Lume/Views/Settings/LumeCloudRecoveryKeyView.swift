//
//  LumeCloudRecoveryKeyView.swift
//  Lume
//
//  The Lume Cloud recovery key: shown once after an account is created ("I’ve
//  saved it" clears the Settings badge, "Later" keeps it) and again from
//  Settings ▸ Sync. Plus the sheet that joins an account from a recovery key.
//  The key is never logged.
//

#if !os(tvOS)

    import SwiftUI
    #if canImport(UIKit)
        import UIKit
        import UniformTypeIdentifiers
    #elseif canImport(AppKit)
        import AppKit
    #endif

    /// Where the recovery key view is shown.
    enum LumeCloudRecoveryKeyContext: Equatable {
        /// Right after the account was created, as a sheet: the key comes from
        /// the creation.
        case created(recoveryKey: String)
        /// Pushed from Settings ▸ Sync: the key is read from the joined account.
        case settings
    }

    struct LumeCloudRecoveryKeyView: View {
        let context: LumeCloudRecoveryKeyContext

        var body: some View {
            switch context {
            case let .created(recoveryKey):
                NavigationStack {
                    LumeCloudRecoveryKeyForm(recoveryKey: recoveryKey, isNewAccount: true)
                }
                .interactiveDismissDisabled()
                .lumeCloudSheetFrame()
            case .settings:
                LumeCloudStoredRecoveryKeyForm()
            }
        }
    }

    /// Reads the joined account's key; seeing it counts as viewing it.
    private struct LumeCloudStoredRecoveryKeyForm: View {
        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @State private var recoveryKey: String?
        @State private var errorMessage: String?

        var body: some View {
            Group {
                if let recoveryKey {
                    LumeCloudRecoveryKeyForm(recoveryKey: recoveryKey, isNewAccount: false)
                } else {
                    Form {
                        if let errorMessage {
                            Section {
                                Text(errorMessage)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .platformNavigationTitle("Recovery Key")
                }
            }
            .task {
                guard recoveryKey == nil else { return }
                do {
                    guard let coordinator else { throw LumeCloudAccountError.unavailable }
                    recoveryKey = try coordinator.revealLumeCloudRecoveryKey()
                } catch {
                    errorMessage = LumeCloudErrorDescription.message(for: error)
                }
            }
        }
    }

    private struct LumeCloudRecoveryKeyForm: View {
        let recoveryKey: String
        let isNewAccount: Bool

        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @Environment(\.dismiss) private var dismiss
        @State private var didCopy = false

        var body: some View {
            Form {
                Section {
                    LumeCloudRecoveryKeyText(recoveryKey: recoveryKey)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } header: {
                    Text("Recovery Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("If you lose all your devices, this key is the only way back to your Lume Cloud data. Without it, your synced data is gone.")
                        Text("Store it somewhere safe, like a password manager. Never share it.")
                    }
                }
                Section {
                    Button(didCopy ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"), systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                        copy()
                    }
                    ShareLink(item: recoveryKey) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                if isNewAccount {
                    Section {
                        Button("I’ve saved it") {
                            coordinator?.markLumeCloudRecoveryKeyViewed()
                            dismiss()
                        }
                        .bold()
                        Button("Later") { dismiss() }
                    } footer: {
                        Text("You can find this key later in Settings ▸ Sync.")
                    }
                }
            }
            .formStyle(.grouped)
            .platformNavigationTitle("Recovery Key")
            .task(id: didCopy) {
                guard didCopy else { return }
                try? await Task.sleep(for: .seconds(2))
                didCopy = false
            }
        }

        private func copy() {
            LumeCloudRecoveryKeyPasteboard.copy(recoveryKey)
            didCopy = true
        }
    }

    /// The recovery key at reading size: left to right in every locale and
    /// spelled out by VoiceOver.
    private struct LumeCloudRecoveryKeyText: View {
        let recoveryKey: String

        var body: some View {
            Text(verbatim: recoveryKey)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
                .privacySensitive()
                .accessibilityLabel(
                    Text(verbatim: recoveryKey.replacingOccurrences(of: "-", with: ", "))
                        .speechSpellsOutCharacters()
                )
        }
    }

    /// Copies the recovery key for this device only: never handed to Universal
    /// Clipboard, and it expires from the clipboard after a while.
    private enum LumeCloudRecoveryKeyPasteboard {
        static let lifetime: TimeInterval = 300

        static func copy(_ recoveryKey: String) {
            #if canImport(UIKit)
                UIPasteboard.general.setItems(
                    [[UTType.plainText.identifier: recoveryKey]],
                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)]
                )
            #elseif canImport(AppKit)
                let pasteboard = NSPasteboard.general
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                pasteboard.setString(recoveryKey, forType: .string)
                let copied = pasteboard.changeCount
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(lifetime))
                    // Leaves alone anything copied since.
                    guard pasteboard.changeCount == copied else { return }
                    pasteboard.clearContents()
                }
            #endif
        }
    }

    // MARK: - Restore

    /// Joins the Lume Cloud account a recovery key belongs to, then makes Lume
    /// Cloud this device's backend.
    struct LumeCloudRestoreSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(CloudSyncCoordinator.self) private var coordinator: CloudSyncCoordinator?
        @State private var model = LumeCloudRestoreModel()

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("Recovery Key", text: $model.recoveryKey, prompt: Text(verbatim: "XXXX-XXXX-XXXX-…"), axis: .vertical)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                            .privacySensitive()
                            .disabled(model.isWorking)
                        #if os(iOS) || os(visionOS)
                            .textInputAutocapitalization(.characters)
                        #endif
                    } header: {
                        Text("Recovery Key")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Enter the recovery key you saved when you created your Lume Cloud account.")
                            Text(SyncSettingsPromptText.privacyNote)
                        }
                    }
                    if model.isWorking {
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
                .platformNavigationTitle("Restore from Recovery Key")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore") { restore() }
                            .disabled(!model.canRestore)
                    }
                }
            }
            .interactiveDismissDisabled(model.isWorking)
            #if os(macOS)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
            #endif
        }

        private func restore() {
            guard model.canRestore else { return }
            Task {
                if await model.restore(using: coordinator) {
                    dismiss()
                }
            }
        }
    }

#endif
