//
//  TraktIntegrationView.swift
//  Lume
//
//  The iOS/macOS Trakt integration screen (the tvOS surface lives inline in
//  SettingsView's Integrations pane). Drives the OAuth device flow: shows the
//  activation code with a one-tap link to open trakt.tv/activate, polls in the
//  background, and surfaces the connected account with a disconnect action.
//

#if !os(tvOS)

    import SwiftUI

    struct TraktIntegrationView: View {
        @State private var trakt = TraktService.shared
        /// Trakt is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.openURL) private var openURL

        var body: some View {
            List {
                if trakt.isConnected {
                    connectedSection
                } else if let code = trakt.pendingCode {
                    deviceCodeSection(code)
                } else {
                    connectSection
                }
            }
            .platformNavigationTitle("Trakt")
            .paywall(isPresented: $showPaywall, highlight: .trakt)
            .onDisappear {
                // Stop polling if the user backs out mid-connect.
                if !trakt.isConnected { trakt.cancelConnect() }
            }
        }

        // MARK: - Connect

        private var connectSection: some View {
            Section {
                Button {
                    if premium.isPremium {
                        trakt.connect()
                    } else {
                        showPaywall = true
                    }
                } label: {
                    Label("Connect Trakt Account", systemImage: premium.isPremium ? "link" : "crown")
                }
                .disabled(trakt.isConnecting)
            } header: {
                Text("Trakt")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync the movies and episodes you watch to Trakt, and surface your Trakt watchlist on Home.")
                    if let error = trakt.connectionError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }

        // MARK: - Device code

        private func deviceCodeSection(_ code: TraktDeviceCode) -> some View {
            Section {
                VStack(spacing: 16) {
                    Text("Enter this code at trakt.tv/activate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(code.userCode)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .textSelection(.enabled)

                    if let url = TraktClient.activationURL(for: code.userCode) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open trakt.tv/activate", systemImage: "safari")
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
                        trakt.cancelConnect()
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
                        if let username = trakt.username {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                Button(role: .destructive) {
                    Task { await trakt.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "link.badge.plus")
                }
            } header: {
                Text("Trakt")
            } footer: {
                Text("Watched movies and episodes sync to your Trakt history.")
            }
        }
    }

#endif
