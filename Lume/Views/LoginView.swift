import SwiftData
import SwiftUI
#if !os(tvOS)
    import UniformTypeIdentifiers
#endif

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

    @State private var sourceType: PlaylistSourceType = .xtream

    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""

    // m3u fields
    @State private var m3uURL = ""
    @State private var epgURL = ""
    #if !os(tvOS)
        @State private var showFileImporter = false
    #endif

    // Stalker portal fields. The MAC defaults to a freshly generated MAG-style
    // address so a user without a provider-issued MAC still gets a valid one.
    @State private var portalURL = ""
    @State private var macAddress = StalkerMAC.generate()

    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isFormValid: Bool {
        switch sourceType {
        case .xtream:
            !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
        case .m3u:
            !m3uURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .stalker:
            !portalURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && StalkerMAC.isValid(macAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
                        Picker("Playlist Type", selection: $sourceType) {
                            Text("Xtream").tag(PlaylistSourceType.xtream)
                            Text("M3U").tag(PlaylistSourceType.m3u)
                            Text("Stalker").tag(PlaylistSourceType.stalker)
                        }
                        .pickerStyle(.segmented)
                    }

                    switch sourceType {
                    case .xtream: xtreamSection
                    case .m3u: m3uSection
                    case .stalker: stalkerSection
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }

                    Section {
                        Button(action: addPlaylist) {
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
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: Self.playlistFileTypes
                ) { result in
                    handleFileImport(result)
                }
            }
        }

        private var xtreamSection: some View {
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
        }

        private var m3uSection: some View {
            Section {
                TextField("e.g. My IPTV", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://example.com/playlist.m3u", text: $m3uURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                Button("Choose Local File…") { showFileImporter = true }

                TextField("EPG URL (optional)", text: $epgURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)
            } header: {
                Text("M3U Playlist")
            } footer: {
                Text("Enter the playlist URL or choose a local m3u/m3u8 file. The EPG URL is read from the playlist when left empty.")
            }
        }

        private var stalkerSection: some View {
            Section {
                TextField("e.g. My IPTV", text: $name)
                    .textContentType(.name)

                TextField("e.g. http://example.com:8080/c/", text: $portalURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                HStack {
                    TextField("MAC Address", text: $macAddress)
                    #if os(iOS)
                        .textInputAutocapitalization(.characters)
                    #endif
                        .autocorrectionDisabled()
                    Button {
                        macAddress = StalkerMAC.generate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Generate a new MAC address")
                }

                TextField("Username (optional)", text: $username)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.username)

                SecureField("Password (optional)", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Stalker Portal")
            } footer: {
                Text("Enter the portal URL and the MAC address your provider authorized. Most portals need only the portal URL and MAC.")
            }
        }
    #endif

    #if os(tvOS)
        private var stalkerHint: LocalizedStringKey {
            switch sourceType {
            case .xtream: "Your credentials are stored locally on this device."
            case .m3u: "The EPG URL is read from the playlist when left empty."
            case .stalker: "Enter the portal URL and the MAC address your provider authorized."
            }
        }

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

                    Picker("Playlist Type", selection: $sourceType) {
                        Text("Xtream").tag(PlaylistSourceType.xtream)
                        Text("M3U").tag(PlaylistSourceType.m3u)
                        Text("Stalker").tag(PlaylistSourceType.stalker)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    VStack(spacing: 22) {
                        TVSettingsField(title: "Name", placeholder: "e.g. My IPTV", text: $name, contentType: .name)
                        switch sourceType {
                        case .xtream:
                            TVSettingsField(title: "Server URL", placeholder: "e.g. http://example.com:8080", text: $serverURL, contentType: .URL)
                            TVSettingsField(title: "Username", placeholder: "Username", text: $username, contentType: .username)
                            TVSettingsField(title: "Password", placeholder: "Password", text: $password, isSecure: true, contentType: .password)
                        case .m3u:
                            TVSettingsField(title: "Playlist URL", placeholder: "e.g. http://example.com/playlist.m3u", text: $m3uURL, contentType: .URL)
                            TVSettingsField(title: "EPG URL (optional)", placeholder: "e.g. http://example.com/guide.xml", text: $epgURL, contentType: .URL)
                        case .stalker:
                            TVSettingsField(title: "Portal URL", placeholder: "e.g. http://example.com:8080/c/", text: $portalURL, contentType: .URL)
                            TVSettingsField(title: "MAC Address", placeholder: "00:1A:79:xx:xx:xx", text: $macAddress, contentType: nil)
                            TVSettingsField(title: "Username (optional)", placeholder: "Username", text: $username, contentType: .username)
                            TVSettingsField(title: "Password (optional)", placeholder: "Password", text: $password, isSecure: true, contentType: .password)
                        }
                    }

                    Text(stalkerHint)
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
                        Button(action: addPlaylist) {
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

    // MARK: - Add playlist

    private func addPlaylist() {
        switch sourceType {
        case .xtream: loginXtream()
        case .m3u: addM3UPlaylist()
        case .stalker: addStalkerPlaylist()
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loginXtream() {
        isLoading = true
        errorMessage = nil

        let playlistName = trimmedName.isEmpty ? "My Playlist" : trimmedName

        Task {
            let playlist = Playlist(
                name: playlistName,
                serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )

            let client = XtreamClient()
            do {
                try await withConnectionTimeout {
                    let info = try await client.getInfo(playlist: playlist)
                    playlist.serverTimezone = info.serverInfo.timezone
                    playlist.userStatus = info.userInfo.status
                    playlist.maxConnections = String(info.userInfo.maxConnections ?? "0")
                    playlist.activeConnections = String(info.userInfo.activeCons ?? "0")
                    playlist.expDate = info.userInfo.expDate
                    insertAndFinish(playlist)
                }
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func addM3UPlaylist() {
        isLoading = true
        errorMessage = nil

        let playlistName = trimmedName.isEmpty ? "My Playlist" : trimmedName
        // Rewrite Xtream bouquet types (type=gigablue/dreambox → m3u_plus) up
        // front so the stored URL is the one that actually parses.
        let urlString = M3UClient.normalizedPlaylistURL(m3uURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let epgURLString = epgURL.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await withConnectionTimeout {
                    // Cheap validation: stream just the head of the file and check
                    // for m3u markers, so adding a huge playlist stays instant —
                    // the full download happens during the first sync.
                    try await M3UClient().validatePlaylist(at: urlString)
                    let playlist = Playlist(name: playlistName, m3uURL: urlString, epgURL: epgURLString)
                    insertAndFinish(playlist)
                }
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func addStalkerPlaylist() {
        isLoading = true
        errorMessage = nil

        let playlistName = trimmedName.isEmpty ? "My Playlist" : trimmedName
        let portal = portalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = macAddress.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        Task {
            let playlist = Playlist(
                name: playlistName,
                portalURL: portal,
                macAddress: mac,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )

            let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))
            do {
                try await withConnectionTimeout {
                    // Handshake + profile doubles as the connection test.
                    let profile = try await client.authenticate()
                    playlist.userStatus = profile.status
                    playlist.expDate = profile.expDate
                    insertAndFinish(playlist)
                }
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func insertAndFinish(_ playlist: Playlist) {
        modelContext.insert(playlist)
        // Set up the playlist's EPG source so the guide refreshes on its own
        // schedule — EPG is no longer part of the content sync.
        EPGSourceReconciler.reconcile(playlist, in: modelContext)
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
}

// MARK: - Connection-test timeout

private extension LoginView {
    struct ConnectionTimeoutError: LocalizedError {
        var errorDescription: String? {
            String(localized: "The connection timed out. Check the URL and your network, then try again.")
        }
    }

    /// Runs an add-playlist connection test under an overall deadline, cancelling
    /// the in-flight request and surfacing a timeout when it's exceeded.
    ///
    /// Each client has its own per-request timeout and (for Xtream) retry/backoff
    /// tuned for *sync*, where retries matter; left unbounded, a wrong URL or
    /// dead host can hang the add sheet for ~30–90s on a spinner with no way out.
    /// This caps the test (default 20s) without weakening the sync path.
    func withConnectionTimeout(_ seconds: Double = 20, _ operation: @escaping () async throws -> Void) async throws {
        let work = Task { try await operation() }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
        }
        defer { watchdog.cancel() }
        do {
            try await work.value
        } catch {
            if work.isCancelled { throw ConnectionTimeoutError() }
            throw error
        }
    }
}

// MARK: - Local file import (iOS / macOS)

#if !os(tvOS)
    private extension LoginView {
        static var playlistFileTypes: [UTType] {
            var types: [UTType] = [.m3uPlaylist]
            if let m3u8 = UTType(filenameExtension: "m3u8") {
                types.append(m3u8)
            }
            return types
        }

        /// Copies the picked file into the app's Application Support directory
        /// so it stays readable across launches (the picker's URL is outside
        /// our sandbox and its security scope doesn't persist), then points the
        /// playlist URL field at the copy.
        func handleFileImport(_ result: Result<URL, Error>) {
            switch result {
            case let .success(pickedURL):
                let accessing = pickedURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing { pickedURL.stopAccessingSecurityScopedResource() }
                }
                do {
                    let directory = try FileManager.default
                        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        .appendingPathComponent("Playlists", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "m3u" : pickedURL.pathExtension)
                    try FileManager.default.copyItem(at: pickedURL, to: destination)
                    m3uURL = destination.absoluteString
                    if trimmedName.isEmpty {
                        name = pickedURL.deletingPathExtension().lastPathComponent
                    }
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            case let .failure(error):
                errorMessage = error.localizedDescription
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
