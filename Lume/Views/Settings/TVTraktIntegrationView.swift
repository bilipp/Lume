//
//  TVTraktIntegrationView.swift
//  Lume
//
//  The tvOS Integrations pane content for Trakt, shown inside SettingsView's
//  detail column. Drives the OAuth device flow with a scannable QR code (Apple
//  TV can't open a browser), and surfaces the connected account.
//

#if os(tvOS)

    import SwiftUI

    struct TVTraktIntegrationView: View {
        @State private var trakt = TraktService.shared
        /// Trakt is a Premium feature.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Trakt")

                if trakt.isConnected {
                    connected
                } else if let code = trakt.pendingCode {
                    deviceCode(code)
                } else {
                    connect
                }
            }
            .paywall(isPresented: $showPaywall, highlight: .trakt)
        }

        private var connect: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync the movies and episodes you watch to Trakt, and surface your Trakt watchlist on Home.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    if premium.isPremium {
                        trakt.connect()
                    } else {
                        showPaywall = true
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: premium.isPremium ? "link" : "sparkles")
                            .font(.system(size: 22, weight: .medium))
                        Text("Connect Trakt Account")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(trakt.isConnecting)

                if let error = trakt.connectionError {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
        }

        private func deviceCode(_ code: TraktDeviceCode) -> some View {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("On your phone or computer, go to")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("trakt.tv/activate")
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
                        trakt.cancelConnect()
                    }
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .padding(.top, 8)
                }

                if let url = TraktClient.activationURL(for: code.userCode) {
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
                TVSettingsValueRow("Connected", value: trakt.username.map { "@\($0)" } ?? "—")

                Text("Watched movies and episodes sync to your Trakt history.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    Task { await trakt.disconnect() }
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
    }

#endif
