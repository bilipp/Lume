//
//  TVSimklIntegrationView.swift
//  Lume
//
//  The tvOS Integrations pane content for Simkl, shown inside SettingsView's
//  detail column. Drives the OAuth device flow with a scannable QR code (Apple
//  TV can't open a browser), and surfaces the connected account.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVSimklIntegrationView: View {
        @State private var simkl = SimklService.shared
        /// Simkl is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Simkl")

                if simkl.isConnected {
                    connected
                } else if let code = simkl.pendingCode {
                    deviceCode(code)
                } else {
                    connect
                }
            }
            .paywall(isPresented: $showPaywall, highlight: .simkl)
        }

        private var connect: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync the movies and episodes you watch to Simkl.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    if premium.isPremium {
                        simkl.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: premium.isPremium ? "link" : "crown")
                            .font(.system(size: 22, weight: .medium))
                        Text("Connect Simkl Account")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(simkl.isConnecting)

                if let error = simkl.connectionError {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
        }

        private func deviceCode(_ code: SimklDeviceCode) -> some View {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("On your phone or computer, go to")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("simkl.com/pin")
                        .font(.system(size: 30, weight: .semibold))

                    Text("Enter this code")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Text(code.userCode)
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .tracking(6)

                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for authorization…")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    Button("Cancel") {
                        simkl.cancelConnect()
                    }
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .padding(.top, 8)
                }

                if let url = SimklClient.activationURL(for: code) {
                    VStack(spacing: 12) {
                        QRCodeView(string: url.absoluteString)
                            .frame(width: 240, height: 240)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text("Scan to open")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.top, 8)
        }

        private var connected: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsValueRow("Connected", value: simkl.username.map { "@\($0)" } ?? "—")

                Text("Watched movies and episodes sync to your Simkl history. Import marks titles you've already watched on Simkl as watched here.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    Task { await simkl.importWatched(into: modelContext) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 22, weight: .medium))
                        Text("Import Watched from Simkl")
                        Spacer(minLength: 0)
                        if simkl.isImporting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(simkl.isImporting)

                if let summary = simkl.lastImport {
                    importStatus(summary)
                }

                Button {
                    Task { await simkl.disconnect() }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 22, weight: .medium))
                        Text("Disconnect")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
            }
        }

        private func importStatus(_ summary: SimklImportSummary) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                if summary.failed {
                    Text("Couldn't import from Simkl. Please try again.")
                } else if summary.markedNothing {
                    Text("Your watched history is already up to date.")
                } else {
                    Text("Imported \(summary.moviesMarked) movie\(summary.moviesMarked == 1 ? "" : "s") and \(summary.episodesMarked) episode\(summary.episodesMarked == 1 ? "" : "s").")
                    if summary.showsQueued > 0 {
                        Text("\(summary.showsQueued) show\(summary.showsQueued == 1 ? "" : "s") will be marked the first time you open them.")
                    }
                }
            }
            .font(.system(size: 22))
            .foregroundStyle(summary.failed ? .red : .green)
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }
    }

#endif
