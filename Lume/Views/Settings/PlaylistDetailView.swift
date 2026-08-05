import SwiftData
import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
    @Bindable var playlist: Playlist

    /// tvOS: called to leave this detail when it is shown inline in the Settings
    /// detail pane (e.g. after deleting the playlist, whose object then becomes
    /// invalid). Unused on iOS/macOS, where the view is pushed and `dismiss()`
    /// pops it.
    var onClose: (() -> Void)?

    @State var isEditing = false
    @State var editName = ""
    @State var editServerURL = ""
    @State var editUsername = ""
    @State var editPassword = ""
    @State var editEPGURL = ""
    @State var editMacAddress = ""
    @State var showDeleteConfirmation = false
    @State var showSync = false
    /// Presents the full-catalog download (Stalker only). Kept separate from
    /// `showSync` so the two sheets carry different `full` flags.
    @State var showFullSync = false

    var isM3U: Bool {
        playlist.sourceType == .m3u
    }

    var isStalker: Bool {
        playlist.sourceType == .stalker
    }

    /// The localized section heading for the connection fields.
    var connectionSectionTitle: LocalizedStringKey {
        switch playlist.sourceType {
        case .xtream: "Server"
        case .m3u: "M3U Playlist"
        case .stalker: "Stalker Portal"
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
            Form {
                if isEditing {
                    editingSection
                } else {
                    readOnlySection
                }

                if let status = playlist.userStatus {
                    Section("Account") {
                        LabeledContent("Status", value: status)
                        if let expDate = playlist.expDate {
                            LabeledContent("Expires") {
                                Text(formattedExpiry(expDate))
                                    .foregroundStyle(isExpired(expDate) ? .red : .secondary)
                            }
                        }
                        if let maxConn = playlist.maxConnections {
                            LabeledContent("Max Connections", value: maxConn)
                        }
                        if let activeConn = playlist.activeConnections {
                            LabeledContent("Active Connections", value: activeConn)
                        }
                    }
                }

                if playlist.supportsStreamFormatChoice {
                    streamFormatSection
                }

                syncSection

                Section {
                    Button("Delete Playlist", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(playlist.name)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if isEditing {
                            Button("Done") { saveChanges() }
                        } else {
                            Button("Edit") { startEditing() }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        if isEditing {
                            Button("Cancel") { cancelEditing() }
                        }
                    }
                }
                .alert("Delete Playlist", isPresented: $showDeleteConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { deletePlaylist() }
                } message: {
                    Text("All synced content for this playlist will also be removed.")
                }
                .sheet(isPresented: $showSync) {
                    SyncProgressView(playlist: playlist)
                }
                .sheet(isPresented: $showFullSync) {
                    SyncProgressView(playlist: playlist, full: true)
                }
        }
    #endif

    #if !os(tvOS)

        // MARK: - Server Section (Read-only)

        private var readOnlySection: some View {
            Section(connectionSectionTitle) {
                LabeledContent("Name", value: playlist.name)
                LabeledContent(isStalker ? "Portal URL" : "URL") {
                    Text(playlist.serverURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                if isM3U {
                    LabeledContent("EPG URL") {
                        Text(playlist.epgURL ?? String(localized: "None"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                } else if isStalker {
                    LabeledContent("MAC Address", value: playlist.macAddress ?? "")
                    if !playlist.username.isEmpty {
                        LabeledContent("Username", value: playlist.username)
                    }
                } else {
                    LabeledContent("Username", value: playlist.username)
                    LabeledContent("Password") {
                        Text("••••••••")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Added") {
                    Text(playlist.addedAt, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // MARK: - Server Section (Editing)

        private var editingSection: some View {
            Section(connectionSectionTitle) {
                TextField("Name", text: $editName)
                TextField(serverURLFieldTitle, text: $editServerURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                if isM3U {
                    TextField("EPG URL (optional)", text: $editEPGURL)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                } else if isStalker {
                    TextField("MAC Address", text: $editMacAddress)
                    #if os(iOS)
                        .textInputAutocapitalization(.characters)
                    #endif
                        .autocorrectionDisabled()
                    TextField("Username (optional)", text: $editUsername)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password (optional)", text: $editPassword)
                        .textContentType(.password)
                } else {
                    TextField("Username", text: $editUsername)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $editPassword)
                        .textContentType(.password)
                }
            }
        }

        // MARK: - Stream Format Section

        private var streamFormatSection: some View {
            Section {
                Picker("Live Stream Format", selection: $playlist.streamFormat) {
                    ForEach(PlaylistStreamFormat.allCases) { format in
                        Text(verbatim: format.displayName).tag(format)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text(streamFormatFooter)
            }
        }

        // MARK: - Sync Section

        private var syncSection: some View {
            Section {
                Toggle("Sync Enabled", isOn: $playlist.syncEnabled)

                if playlist.syncStatus == .syncing {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let lastSync = playlist.lastSyncDate {
                    LabeledContent("Last Synced") {
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Sync Now") {
                    showSync = true
                }
                .disabled(playlist.syncStatus == .syncing)

                if isStalker {
                    Button("Download Full Catalog") {
                        showFullSync = true
                    }
                    .disabled(playlist.syncStatus == .syncing)
                }
            } header: {
                Text("Sync")
            } footer: {
                if isStalker {
                    // The portal serves ~14 items per request with no bulk
                    // endpoint, so a default sync only loads the newest titles;
                    // the full catalog is opt-in because it can take a while.
                    Text("""
                    Movies and series load as you browse — nothing is prefetched. \
                    Download the full catalog to make everything available offline and \
                    searchable at once; this can take a while on large portals.
                    """)
                }
            }
        }
    #endif

    /// Explains the stream-format choice. m3u playlists carry their own URLs, so
    /// the wording there is about rewriting them rather than picking a default.
    var streamFormatFooter: LocalizedStringKey {
        isM3U
            ? "Automatic plays channels at the URL the playlist lists. Choose HLS or MPEG-TS to request that container instead; channels served through another kind of URL are unaffected."
            : "Automatic requests live channels as HLS. Choose MPEG-TS if channels stutter, refuse to start, or drop out — servers often serve one container more reliably than the other."
    }

    /// Field label for the primary URL, shared across the iOS/macOS and tvOS
    /// layouts — its wording depends on the playlist's source type.
    var serverURLFieldTitle: LocalizedStringKey {
        switch playlist.sourceType {
        case .xtream: "Server URL"
        case .m3u: "Playlist URL"
        case .stalker: "Portal URL"
        }
    }
}

// MARK: - Actions

extension PlaylistDetailView {
    func startEditing() {
        editName = playlist.name
        editServerURL = playlist.serverURL
        editUsername = playlist.username
        editPassword = playlist.password
        editEPGURL = playlist.epgURL ?? ""
        editMacAddress = playlist.macAddress ?? ""
        withAnimation { isEditing = true }
    }

    func cancelEditing() {
        withAnimation { isEditing = false }
    }

    func saveChanges() {
        playlist.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        playlist.serverURL = editServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if isM3U {
            let epgURL = editEPGURL.trimmingCharacters(in: .whitespacesAndNewlines)
            playlist.epgURL = epgURL.isEmpty ? nil : epgURL
        } else if isStalker {
            playlist.macAddress = editMacAddress.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            playlist.username = editUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            playlist.password = editPassword
        } else {
            playlist.username = editUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            playlist.password = editPassword
        }
        playlist.lastUpdated = Date()
        // Keep the playlist's EPG source in step with its (possibly changed)
        // guide URL / credentials.
        EPGSourceReconciler.reconcile(playlist, in: modelContext)
        withAnimation { isEditing = false }
    }

    func deletePlaylist() {
        // Route through the sync engine so the deletion also clears the
        // CloudKit mirror and shadow baseline — deleting on the view context
        // alone leaves a surviving mirror that resurrects the last playlist
        // (#136). Previews have no coordinator; local-only deletion is fine.
        if let cloudSync {
            let id = playlist.id
            Task { await cloudSync.deletePlaylist(id: id) }
        } else {
            PlaylistDeletion.delete(playlist, in: modelContext)
        }
        #if os(tvOS)
            onClose?()
        #else
            dismiss()
        #endif
    }
}

// MARK: - Helpers

extension PlaylistDetailView {
    func formattedExpiry(_ raw: String) -> String {
        if let timestamp = TimeInterval(raw) {
            let date = Date(timeIntervalSince1970: timestamp)
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return raw
    }

    func isExpired(_ raw: String) -> Bool {
        guard let timestamp = TimeInterval(raw) else { return false }
        let date = Date(timeIntervalSince1970: timestamp)
        return date < Date()
    }
}

#Preview("With Account Info") {
    let container = previewContainer()
    let playlist = PreviewData.samplePlaylist
    return NavigationStack {
        PlaylistDetailView(playlist: playlist)
    }
    .modelContainer(container)
}

#Preview("No Account Info") {
    let container = previewContainer()
    let playlist = PreviewData.samplePlaylist
    playlist.userStatus = nil
    playlist.expDate = nil
    playlist.maxConnections = nil
    playlist.activeConnections = nil
    return NavigationStack {
        PlaylistDetailView(playlist: playlist)
    }
    .modelContainer(container)
}

#Preview("No Sync") {
    let container = previewContainer()
    let playlist = PreviewData.samplePlaylist
    playlist.lastSyncDate = nil
    playlist.syncEnabled = false
    return NavigationStack {
        PlaylistDetailView(playlist: playlist)
    }
    .modelContainer(container)
}
