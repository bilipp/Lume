import SwiftData
import SwiftUI

struct LoginView: View {
    /// Whether this view is presented modally (the Settings "Add Playlist"
    /// sheet / cover) and should therefore offer a Cancel button and dismiss
    /// itself once a playlist is added. False when it's the window's root
    /// content on first launch — there is nothing to cancel to, and on macOS
    /// calling `dismiss()` on root content closes the whole window (the app
    /// keeps running but loses its only window, forcing a relaunch from the
    /// Dock). Adding the playlist swaps the root to MainTabView on its own via
    /// ContentView's @Query, so no dismissal is needed there.
    ///
    /// This is passed explicitly rather than read from `@Environment(\.isPresented)`
    /// because on macOS that value is `true` even for non-presented root content.
    var isModal = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""

    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isFormValid: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            formBody
        #endif
    }

    #if !os(tvOS)
        private var formBody: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("e.g. My IPTV", text: $name)
                            .textContentType(.name)

                        TextField("e.g. http://example.com:8080", text: $serverURL)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                            .autocorrectionDisabled()
                            .textContentType(.URL)

                        TextField("Username", text: $username)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                            .autocorrectionDisabled()
                            .textContentType(.username)

                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    } header: {
                        Text("Server Connection")
                    } footer: {
                        Text("Your credentials are stored locally on this device.")
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }

                    Section {
                        Button(action: login) {
                            HStack {
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Add Playlist")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!isFormValid || isLoading)
                    }
                }
                #if os(macOS)
                .formStyle(.grouped)
                #endif
                .navigationTitle("Add Playlist")
                .toolbar {
                    // Only offer Cancel when presented modally (the Settings
                    // sheet). On first launch there is nothing to cancel to.
                    if isModal {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                                .disabled(isLoading)
                        }
                    }
                }
                .interactiveDismissDisabled(isLoading)
            }
        }
    #endif

    #if os(tvOS)
        private var tvBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add Playlist")
                            .font(.system(size: 38, weight: .bold))
                        Text("Connect to your IPTV provider")
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    VStack(spacing: 22) {
                        TVSettingsField(title: "Name", placeholder: "e.g. My IPTV", text: $name, contentType: .name)
                        TVSettingsField(title: "Server URL", placeholder: "e.g. http://example.com:8080", text: $serverURL, contentType: .URL)
                        TVSettingsField(title: "Username", placeholder: "Username", text: $username, contentType: .username)
                        TVSettingsField(title: "Password", placeholder: "Password", text: $password, isSecure: true, contentType: .password)
                    }

                    Text("Your credentials are stored locally on this device.")
                        .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.red)
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    }

                    HStack(spacing: 16) {
                        Button(action: login) {
                            if isLoading {
                                ProgressView()
                            } else {
                                Label("Add Playlist", systemImage: "plus")
                            }
                        }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                        .disabled(!isFormValid || isLoading)

                        // Only offer Cancel when presented modally (the Settings
                        // cover); on first launch there is nothing to cancel to.
                        if isModal {
                            Button("Cancel") { dismiss() }
                                .buttonStyle(TVSettingsActionButtonStyle())
                                .disabled(isLoading)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .padding(.vertical, 72)
            }
            .tvSettingsBackground()
        }
    #endif

    private func login() {
        isLoading = true
        errorMessage = nil

        let playlistName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "My Playlist"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let playlist = Playlist(
                name: playlistName,
                serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )

            let client = XtreamClient()
            do {
                let info = try await client.getInfo(playlist: playlist)

                await MainActor.run {
                    playlist.serverTimezone = info.serverInfo.timezone
                    playlist.userStatus = info.userInfo.status
                    playlist.maxConnections = String(info.userInfo.maxConnections ?? "0")
                    playlist.activeConnections = String(info.userInfo.activeCons ?? "0")
                    playlist.expDate = info.userInfo.expDate

                    modelContext.insert(playlist)
                    // Persist immediately so the ContentSyncManager actor's
                    // separate ModelContext can fetch the playlist. Without this
                    // the autosave is deferred and the sync's fresh context
                    // fetches nil, silently completing without syncing.
                    try? modelContext.save()
                    isLoading = false
                    // Only dismiss when presented modally (e.g. the Settings
                    // sheet). On first launch LoginView is the window's root
                    // content, where dismiss() closes the window on macOS and
                    // leaves the app with no visible window. Inserting the
                    // playlist already swaps the root over to MainTabView via
                    // ContentView's @Query.
                    if isModal {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

#Preview("Empty") {
    LoginView()
}

#Preview("With Error") {
    LoginView()
    // Note: error state is managed internally, shown via the errorMessage field.
    // In previews this can be simulated by setting initial state.
}
