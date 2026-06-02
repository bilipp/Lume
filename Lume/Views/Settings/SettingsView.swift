import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var playlists: [Playlist]
    @State private var showingAddPlaylist = false
    @AppStorage(PlayerSettings.engineKey) private var engineRaw: String = PlayerEngineKind.defaultValue.rawValue

    private var engine: Binding<PlayerEngineKind> {
        Binding(
            get: { PlayerEngineKind(rawValue: engineRaw) ?? .defaultValue },
            set: { engineRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                playlistsSection
                playerSection
                aboutSection
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .platformNavigationTitle("Settings")
            .sheet(isPresented: $showingAddPlaylist) {
                LoginView()
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 600)
        #endif
    }

    private var playlistsSection: some View {
        Section {
            if playlists.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("No Playlists")
                            .foregroundStyle(.secondary)
                        Button("Add Playlist") {
                            showingAddPlaylist = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .listRowInsets(EdgeInsets())
            } else {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tv")
                                .foregroundStyle(.secondary)
                                .font(.body)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name)
                                Text(playlist.serverURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                .onDelete(perform: deletePlaylists)

                Button {
                    showingAddPlaylist = true
                } label: {
                    Label("Add Playlist", systemImage: "plus")
                }
            }
        } header: {
            Text("Playlists")
        } footer: {
            if !playlists.isEmpty {
                Text("\(playlists.count) playlist\(playlists.count == 1 ? "" : "s")")
            }
        }
    }

    private var playerSection: some View {
        Section {
            Picker("Engine", selection: engine) {
                ForEach(PlayerEngineKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)

            Text(engine.wrappedValue.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Player")
        }
    }

    private var aboutSection: some View {
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
        }
    }

    private func deletePlaylists(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(playlists[index])
            }
        }
    }
}

#Preview("Empty") {
    SettingsView()
}

#Preview("With Playlists") {
    SettingsView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                let backup = Playlist(name: "Backup", serverURL: "http://backup.com:8080", username: "user2", password: "pass2")
                container.mainContext.insert(playlist)
                container.mainContext.insert(backup)
            }
        }
}
