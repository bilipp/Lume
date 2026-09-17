//
//  TVOpenSubtitlesIntegrationView.swift
//  Lume
//
//  The tvOS Integrations pane content for OpenSubtitles, shown inside
//  SettingsView's detail column alongside Trakt. Sign-in is a plain
//  username/password pair — OpenSubtitles has no device flow, so unlike Trakt
//  there is nothing to scan.
//

#if os(tvOS)

    import SwiftUI

    struct TVOpenSubtitlesIntegrationView: View {
        /// Drops the explanatory paragraph, keeping only the actionable hint.
        /// The in-player overlay raises this above the search results, where a
        /// two-paragraph preamble pushes what the viewer came for off-screen.
        var isCompact = false

        @State private var service = OpenSubtitlesService.shared
        @State private var username = ""
        @State private var password = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("OpenSubtitles")

                if service.isSignedIn {
                    signedIn
                } else {
                    signIn
                }
            }
        }

        private var signIn: some View {
            VStack(alignment: .leading, spacing: 16) {
                if !isCompact {
                    Text("Sign in with your free opensubtitles.com account to download subtitles for movies and episodes from the player's subtitle menu.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Text("Enter your username, not the email address you registered with — OpenSubtitles rejects an email here.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                TVSettingsField(
                    title: "Username",
                    placeholder: "Username",
                    text: $username,
                    contentType: .username
                )

                TVSettingsField(
                    title: "Password",
                    placeholder: "Password",
                    text: $password,
                    isSecure: true,
                    contentType: .password
                )

                Button {
                    Task { await service.signIn(username: username, password: password) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 22, weight: .medium))
                        Text("Sign In")
                        Spacer(minLength: 0)
                        if service.isSigningIn { ProgressView() }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(service.isSigningIn || username.isEmpty || password.isEmpty)

                if let error = service.signInError {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
        }

        private var signedIn: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsValueRow("Signed In", value: service.username ?? "—")

                Text("Search for subtitles from the player's subtitle menu while a movie or episode is playing.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    Task { await service.signOut() }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 22, weight: .medium))
                        Text("Sign Out")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
            }
        }
    }

#endif
