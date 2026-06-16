//
//  SettingsView+Support.swift
//  Lume
//
//  The "Support" links (website, email, Discord), split out of SettingsView to
//  keep that type's body within the file-size limit. On iOS / macOS these are
//  tappable rows that open Safari / Mail / Discord; on tvOS — where the system
//  can't open a URL — the website and Discord are shown as QR codes to scan with
//  a phone (the same pattern as the Trakt device flow), with email as a
//  read-only row. Links live in SupportInfo so both surfaces stay in sync.
//

import SwiftUI

extension SettingsView {
    #if !os(tvOS)
        /// iOS / macOS grouped-list section of tappable support links.
        var supportSection: some View {
            Section {
                if let url = SupportInfo.websiteURL {
                    Link(destination: url) {
                        Label("Website", systemImage: "globe")
                    }
                }
                if let url = SupportInfo.emailURL {
                    Link(destination: url) {
                        Label("Email", systemImage: "envelope")
                    }
                }
                if let url = SupportInfo.discordURL {
                    Link(destination: url) {
                        Label("Discord", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            } header: {
                Text("Support")
            } footer: {
                Text("Get help, request a feature, or report a problem.")
            }
        }

        /// iOS / macOS About section: app identity plus a link to the credits /
        /// licenses screen.
        var aboutSection: some View {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "play.tv.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lume")
                        Text("Version 1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                NavigationLink {
                    CreditsView()
                } label: {
                    Label("Acknowledgements", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
    #else
        /// tvOS About-pane section. Apple TV can't open a URL, so the website and
        /// Discord are scannable QR codes and the support address is a read-only row.
        var tvSupportSection: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Support")

                Text("Scan a code with your phone to open our website or Discord, or email us for help.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                HStack(alignment: .top, spacing: 40) {
                    supportQRCode(caption: "Website", value: SupportInfo.websiteDisplay, link: SupportInfo.website)
                    supportQRCode(caption: "Discord", value: SupportInfo.discordDisplay, link: SupportInfo.discord)
                }
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 4)

                TVSettingsValueRow("Email", value: SupportInfo.email)
                    .padding(.top, 8)
            }
        }

        /// A scannable QR code over its label and (scheme-stripped) URL. The white
        /// inset around the modules is the quiet zone scanners need.
        private func supportQRCode(caption: LocalizedStringKey, value: String, link: String) -> some View {
            VStack(spacing: 10) {
                QRCodeView(string: link)
                    .frame(width: 180, height: 180)
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(caption)
                    .font(.system(size: 22, weight: .semibold))
                Text(verbatim: value)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    #endif
}
