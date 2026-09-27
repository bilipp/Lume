//
//  SettingsView+Support.swift
//  Lume
//
//  Help & Feedback and About. On iOS / macOS they are the last two groups of
//  the root list: the support links (website, email, Discord) are tappable
//  rows that open Safari / Mail / Discord, next to the diagnostic report; on
//  tvOS they are sidebar panes, and — where the system
//  can't open a URL — the website and Discord are shown as QR codes to scan with
//  a phone (the same pattern as the Trakt device flow), with email as a
//  read-only row. Links live in SupportInfo so both surfaces stay in sync.
//

import SwiftUI

#if !os(tvOS)

    /// The root list's Help & Feedback group: the support links, then the
    /// diagnostic report.
    struct HelpFeedbackSection: View {
        var body: some View {
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
                if let url = SupportInfo.appStoreReviewURL {
                    Link(destination: url) {
                        Label("Rate Lume", systemImage: "star")
                    }
                }
                NavigationLink {
                    DebugSettingsView()
                } label: {
                    Label("Send Diagnostic Report", systemImage: "stethoscope")
                }
            } header: {
                Text("Help & Feedback")
            }
        }
    }

    /// The root list's About group: app identity plus a link to the credits /
    /// licenses screen.
    struct AboutSection: View {
        var body: some View {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "play.tv.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lume")
                        Text("Version \(SupportInfo.appVersion)")
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
            } header: {
                Text("About")
            }
        }
    }

#endif

extension SettingsView {
    #if os(tvOS)
        /// tvOS Help & Feedback section. Apple TV can't open a URL, so the website and
        /// Discord are scannable QR codes and the support address is a read-only row.
        var tvSupportSection: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Support")

                Text("Scan the code with your phone to open our Discord.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                HStack(alignment: .top, spacing: 40) {
                    supportQRCode(caption: "Discord", value: SupportInfo.discordDisplay, link: SupportInfo.discord)
                }
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 4)

                VStack(spacing: 2) {
                    TVSettingsValueRow("Website", value: SupportInfo.websiteDisplay)
                    TVSettingsValueRow("Email", value: SupportInfo.email)
                }
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
