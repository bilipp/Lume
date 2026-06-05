import SwiftData
import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var playlist: Playlist

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editServerURL = ""
    @State private var editUsername = ""
    @State private var editPassword = ""
    @State private var showDeleteConfirmation = false
    @State private var showSync = false

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
                    SyncProgressView(playlist: playlist, isPresented: $showSync)
                }
        }
    #endif

    #if !os(tvOS)

        // MARK: - Server Section (Read-only)

        private var readOnlySection: some View {
            Section("Server") {
                LabeledContent("Name", value: playlist.name)
                LabeledContent("URL") {
                    Text(playlist.serverURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Username", value: playlist.username)
                LabeledContent("Password") {
                    Text("••••••••")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Added") {
                    Text(playlist.addedAt, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // MARK: - Server Section (Editing)

        private var editingSection: some View {
            Section("Server") {
                TextField("Name", text: $editName)
                TextField("Server URL", text: $editServerURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .textContentType(.URL)
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

    // MARK: - tvOS layout

    #if os(tvOS)
        private var tvBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text(playlist.name)
                        .font(.system(size: 34, weight: .bold))
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    tvServerSection
                    tvAccountSection
                    tvSyncSection
                    tvActionsSection
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .padding(.vertical, 72)
            }
            .tvSettingsBackground()
            .alert("Delete Playlist", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deletePlaylist() }
            } message: {
                Text("All synced content for this playlist will also be removed.")
            }
            .sheet(isPresented: $showSync) {
                SyncProgressView(playlist: playlist, isPresented: $showSync)
            }
        }

        private var tvServerSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Server")

                if isEditing {
                    VStack(spacing: 18) {
                        TVSettingsField(title: "Name", placeholder: "Name", text: $editName, contentType: .name)
                        TVSettingsField(title: "Server URL", placeholder: "Server URL", text: $editServerURL, contentType: .URL)
                        TVSettingsField(title: "Username", placeholder: "Username", text: $editUsername, contentType: .username)
                        TVSettingsField(title: "Password", placeholder: "Password", text: $editPassword, isSecure: true, contentType: .password)
                    }
                } else {
                    VStack(spacing: 2) {
                        TVSettingsValueRow("Name", value: playlist.name)
                        TVSettingsValueRow("URL") {
                            Text(playlist.serverURL)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        TVSettingsValueRow("Username", value: playlist.username)
                        TVSettingsValueRow("Password") { Text("••••••••") }
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
        withAnimation { isEditing = true }
    }

    private func cancelEditing() {
        withAnimation { isEditing = false }
    }

    private func saveChanges() {
        playlist.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        playlist.serverURL = editServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        playlist.username = editUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        playlist.password = editPassword
        playlist.lastUpdated = Date()
        withAnimation { isEditing = false }
    }

    private func deletePlaylist() {
        modelContext.delete(playlist)
        dismiss()
    }

    // MARK: - Helpers

    private func formattedExpiry(_ raw: String) -> String {
        if let timestamp = TimeInterval(raw) {
            let date = Date(timeIntervalSince1970: timestamp)
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return raw
    }

    private func isExpired(_ raw: String) -> Bool {
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
