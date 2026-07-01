import SwiftData
import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var playlist: Playlist

    /// tvOS: called to leave this detail when it is shown inline in the Settings
    /// detail pane (e.g. after deleting the playlist, whose object then becomes
    /// invalid). Unused on iOS/macOS, where the view is pushed and `dismiss()`
    /// pops it.
    var onClose: (() -> Void)?

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editServerURL = ""
    @State private var editUsername = ""
    @State private var editPassword = ""
    @State private var editEPGURL = ""
    @State private var editMacAddress = ""
    @State private var showDeleteConfirmation = false
    @State private var showSync = false

    private var isM3U: Bool {
        playlist.sourceType == .m3u
    }

    private var isStalker: Bool {
        playlist.sourceType == .stalker
    }

    /// The localized section heading for the connection fields.
    private var connectionSectionTitle: LocalizedStringKey {
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

        // MARK: - Sync Section

        private var syncSection: some View {
            Section("Sync") {
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
            }
        }
    #endif

    /// Field label for the primary URL, shared across the iOS/macOS and tvOS
    /// layouts — its wording depends on the playlist's source type.
    private var serverURLFieldTitle: LocalizedStringKey {
        switch playlist.sourceType {
        case .xtream: "Server URL"
        case .m3u: "Playlist URL"
        case .stalker: "Portal URL"
        }
    }

    // MARK: - tvOS layout

    #if os(tvOS)
        /// Rendered *inline* inside the Settings detail pane (next to the sidebar),
        /// not pushed full-screen. A push hides the TabView's header tab bar and
        /// strands focus once the content scrolls — keeping it in the pane means
        /// the sidebar and tab bar stay one "Left"/"Up" away at all times. The
        /// enclosing pane supplies the ScrollView, background, and width framing.
        private var tvBody: some View {
            VStack(alignment: .leading, spacing: 32) {
                Text(playlist.name)
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                tvServerSection
                tvAccountSection
                tvSyncSection
                tvActionsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alert("Delete Playlist", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deletePlaylist() }
            } message: {
                Text("All synced content for this playlist will also be removed.")
            }
            .fullScreenCover(isPresented: $showSync) {
                SyncProgressView(playlist: playlist)
            }
        }

        private var tvServerSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel(connectionSectionTitle)

                if isEditing {
                    VStack(spacing: 18) {
                        TVSettingsField(title: "Name", placeholder: "Name", text: $editName, contentType: .name)
                        TVSettingsField(title: serverURLFieldTitle, placeholder: serverURLFieldTitle, text: $editServerURL, contentType: .URL)
                        if isM3U {
                            TVSettingsField(title: "EPG URL (optional)", placeholder: "EPG URL", text: $editEPGURL, contentType: .URL)
                        } else if isStalker {
                            TVSettingsField(title: "MAC Address", placeholder: "00:1A:79:xx:xx:xx", text: $editMacAddress, contentType: nil)
                            TVSettingsField(title: "Username (optional)", placeholder: "Username", text: $editUsername, contentType: .username)
                            TVSettingsField(title: "Password (optional)", placeholder: "Password", text: $editPassword, isSecure: true, contentType: .password)
                        } else {
                            TVSettingsField(title: "Username", placeholder: "Username", text: $editUsername, contentType: .username)
                            TVSettingsField(title: "Password", placeholder: "Password", text: $editPassword, isSecure: true, contentType: .password)
                        }
                    }
                } else {
                    VStack(spacing: 2) {
                        TVSettingsValueRow("Name", value: playlist.name)
                        TVSettingsValueRow(isStalker ? "Portal URL" : "URL") {
                            Text(playlist.serverURL)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if isM3U {
                            TVSettingsValueRow("EPG URL") {
                                Text(playlist.epgURL ?? String(localized: "None"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else if isStalker {
                            TVSettingsValueRow("MAC Address", value: playlist.macAddress ?? "")
                            if !playlist.username.isEmpty {
                                TVSettingsValueRow("Username", value: playlist.username)
                            }
                        } else {
                            TVSettingsValueRow("Username", value: playlist.username)
                            TVSettingsValueRow("Password") { Text("••••••••") }
                        }
                        TVSettingsValueRow("Added") { Text(playlist.addedAt, style: .date) }
                    }
                }
            }
        }

        @ViewBuilder
        private var tvAccountSection: some View {
            if let status = playlist.userStatus {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Account")

                    VStack(spacing: 2) {
                        TVSettingsValueRow("Status", value: status)
                        if let expDate = playlist.expDate {
                            TVSettingsValueRow("Expires") {
                                Text(formattedExpiry(expDate))
                                    .foregroundStyle(isExpired(expDate) ? .red : .secondary)
                            }
                        }
                        if let maxConn = playlist.maxConnections {
                            TVSettingsValueRow("Max Connections", value: maxConn)
                        }
                        if let activeConn = playlist.activeConnections {
                            TVSettingsValueRow("Active Connections", value: activeConn)
                        }
                    }
                }
            }
        }

        private var tvSyncSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sync")

                VStack(spacing: 2) {
                    Button {
                        playlist.syncEnabled.toggle()
                    } label: {
                        HStack(spacing: 16) {
                            Text("Sync Enabled")
                            Spacer(minLength: 0)
                            Text(playlist.syncEnabled ? "On" : "Off")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())

                    if playlist.syncStatus == .syncing {
                        TVSettingsValueRow("Status") {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Syncing")
                            }
                        }
                    }

                    if let lastSync = playlist.lastSyncDate {
                        TVSettingsValueRow("Last Synced") {
                            Text(lastSync, style: .relative)
                        }
                    }

                    Button("Sync Now") { showSync = true }
                        .buttonStyle(TVSettingsRowButtonStyle())
                        .disabled(playlist.syncStatus == .syncing)
                }
            }
        }

        private var tvActionsSection: some View {
            VStack(spacing: 2) {
                if isEditing {
                    Button("Done") { saveChanges() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    Button("Cancel") { cancelEditing() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                } else {
                    Button("Edit Playlist") { startEditing() }
                        .buttonStyle(TVSettingsRowButtonStyle())
                    Button("Delete Playlist") { showDeleteConfirmation = true }
                        .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
                }
            }
            .padding(.top, 12)
        }
    #endif

    // MARK: - Actions

    private func startEditing() {
        editName = playlist.name
        editServerURL = playlist.serverURL
        editUsername = playlist.username
        editPassword = playlist.password
        editEPGURL = playlist.epgURL ?? ""
        editMacAddress = playlist.macAddress ?? ""
        withAnimation { isEditing = true }
    }

    private func cancelEditing() {
        withAnimation { isEditing = false }
    }

    private func saveChanges() {
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

    private func deletePlaylist() {
        PlaylistDeletion.delete(playlist, in: modelContext)
        #if os(tvOS)
            onClose?()
        #else
            dismiss()
        #endif
    }
}

// MARK: - Helpers

private extension PlaylistDetailView {
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
