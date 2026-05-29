import SwiftUI
import SwiftData

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

#Preview {
    LoginView()
}
