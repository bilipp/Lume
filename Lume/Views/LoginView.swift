import SwiftData
import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
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
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isLoading)
                    }
                }
                .interactiveDismissDisabled(isLoading)
            }
        }
    #endif

    #if os(tvOS)
        @FocusState private var focusedField: LoginField?

        private var tvBody: some View {
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.13), Color(white: 0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 10) {
                            Text("Add Playlist")
                                .font(.system(size: 62, weight: .bold))
                            Text("Connect to your IPTV provider")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 52)

                        VStack(spacing: 26) {
                            TVField(
                                title: "Name",
                                placeholder: "e.g. My IPTV",
                                text: $name,
                                field: .name,
                                contentType: .name,
                                focused: $focusedField
                            )
                            TVField(
                                title: "Server URL",
                                placeholder: "e.g. http://example.com:8080",
                                text: $serverURL,
                                field: .server,
                                contentType: .URL,
                                focused: $focusedField
                            )
                            TVField(
                                title: "Username",
                                placeholder: "Username",
                                text: $username,
                                field: .username,
                                contentType: .username,
                                focused: $focusedField
                            )
                            TVField(
                                title: "Password",
                                placeholder: "Password",
                                text: $password,
                                isSecure: true,
                                field: .password,
                                contentType: .password,
                                focused: $focusedField
                            )
                        }

                        Text("Your credentials are stored locally on this device.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 22)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 16)
                        }

                        HStack(spacing: 24) {
                            Button(action: login) {
                                ZStack {
                                    if isLoading {
                                        ProgressView()
                                    } else {
                                        Label("Add Playlist", systemImage: "plus")
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                            .buttonStyle(TVGlassButtonStyle())
                            .disabled(!isFormValid || isLoading)

                            Button("Cancel") { dismiss() }
                                .buttonStyle(TVGlassButtonStyle())
                                .disabled(isLoading)
                        }
                        .padding(.top, 44)
                    }
                    .frame(maxWidth: 840)
                    .padding(.horizontal, 60)
                    .padding(.vertical, 80)
                    .frame(maxWidth: .infinity)
                }
                .defaultFocus($focusedField, .name)
            }
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
                    // Only dismiss when presented (e.g. the Settings sheet). On
                    // first run LoginView is the window's root content, where
                    // dismiss() would close the window on macOS and leave the app
                    // with no visible window. Inserting the playlist already swaps
                    // the root over to MainTabView via ContentView's @Query.
                    if isPresented {
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

#if os(tvOS)

    /// Identifies the focusable text inputs in the tvOS login layout.
    private enum LoginField: Hashable {
        case name, server, username, password
    }

    /// A labelled, focus-aware text input styled to match the app's tvOS
    /// controls (`.regularMaterial` pill that fills solid white on focus,
    /// mirroring `TVGlassButtonStyle`).
    private struct TVField: View {
        let title: String
        let placeholder: String
        @Binding var text: String
        var isSecure: Bool = false
        let field: LoginField
        let contentType: UITextContentType
        @FocusState.Binding var focused: LoginField?

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                // Use the native tvOS field appearance for both states. Its
                // focus treatment (white pill + lift) is system-drawn and can't
                // be replaced by a custom background — layering one on top just
                // produces a doubled, mismatched-radius shape. Labels and layout
                // are ours; the field itself stays native.
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textContentType(contentType)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
            }
        }
    }

#endif

#Preview("Empty") {
    LoginView()
}

#Preview("With Error") {
    LoginView()
    // Note: error state is managed internally, shown via the errorMessage field.
    // In previews this can be simulated by setting initial state.
}
