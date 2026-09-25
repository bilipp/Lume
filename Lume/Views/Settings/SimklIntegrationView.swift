//
//  SimklIntegrationView.swift
//  Lume
//
//  The iOS/macOS Simkl integration screen (the tvOS surface lives inline in
//  SettingsView's Integrations pane). Drives the OAuth device flow: shows the
//  activation code with a one-tap link to the pre-filled simkl.com/pin page,
//  polls in the background, and surfaces the connected account with import and
//  disconnect actions.
//

#if !os(tvOS)

    import SwiftData
    import SwiftUI

    struct SimklIntegrationView: View {
        @State private var simkl = SimklService.shared
        /// Simkl is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.openURL) private var openURL
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            List {
                if simkl.isConnected {
                    connectedSection
                } else if let code = simkl.pendingCode {
                    deviceCodeSection(code)
                } else {
                    connectSection
                }
            }
            .platformNavigationTitle("Simkl")
            .paywall(isPresented: $showPaywall, highlight: .simkl)
            .onDisappear {
                // Stop polling if the user backs out mid-connect.
                if !simkl.isConnected {
                    simkl.cancelConnect()
                }
            }
        }

        // MARK: - Connect

        private var connectSection: some View {
            Section {
                Button {
                    if premium.isPremium {
                        simkl.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    Label("Connect Simkl Account", systemImage: premium.isPremium ? "link" : "crown")
                }
                .disabled(simkl.isConnecting)
            } header: {
                Text("Simkl")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync the movies and episodes you watch to Simkl.")
                    if let error = simkl.connectionError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }

        // MARK: - Device code

        private func deviceCodeSection(_ code: SimklDeviceCode) -> some View {
            Section {
                VStack(spacing: 16) {
                    Text("Enter this code at simkl.com/pin")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(code.userCode)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .textSelection(.enabled)

                    if let url = SimklClient.activationURL(for: code) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open simkl.com/pin", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)

                        QRCodeView(string: url.absoluteString)
                            .frame(width: 160, height: 160)
                            .padding(.top, 4)
                    }

                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for authorization…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    Button("Cancel", role: .cancel) {
                        simkl.cancelConnect()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }

        // MARK: - Connected

        private var connectedSection: some View {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connected")
                        if let username = simkl.username {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                Button {
                    Task { await simkl.importWatched(into: modelContext) }
                } label: {
                    HStack {
                        Label("Import Watched from Simkl", systemImage: "arrow.down.circle")
                        if simkl.isImporting {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(simkl.isImporting)

                Button(role: .destructive) {
                    Task { await simkl.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "link.badge.plus")
                }
            } header: {
                Text("Simkl")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watched movies and episodes sync to your Simkl history. Import marks titles you've already watched on Simkl as watched here.")
                    if let summary = simkl.lastImport {
                        importStatus(summary)
                    }
                }
            }
        }

        @ViewBuilder
        private func importStatus(_ summary: SimklImportSummary) -> some View {
            if summary.failed {
                Text("Couldn't import from Simkl. Please try again.")
                    .foregroundStyle(.red)
            } else if summary.markedNothing {
                Text("Your watched history is already up to date.")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported \(summary.moviesMarked) movie\(summary.moviesMarked == 1 ? "" : "s") and \(summary.episodesMarked) episode\(summary.episodesMarked == 1 ? "" : "s").")
                    if summary.showsQueued > 0 {
                        Text("\(summary.showsQueued) show\(summary.showsQueued == 1 ? "" : "s") will be marked the first time you open them.")
                    }
                }
                .foregroundStyle(.green)
            }
        }
    }

#endif
