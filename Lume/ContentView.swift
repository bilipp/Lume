import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    // Optional so previews (which don't inject the coordinator) don't crash;
    // a missing coordinator reads as "gate open", preserving old behaviour.
    @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
    @Query private var playlists: [Playlist]

    var body: some View {
        Group {
            // A populated local store always wins — returning users go straight
            // to the app. On an empty store we wait for the launch-time iCloud
            // sync to settle first, so cloud playlists aren't yanked in
            // mid-typing on a fresh device. If sync is unavailable, errors, or
            // times out, the gate opens and the form shows as a fallback (see
            // CloudSyncCoordinator).
            if !playlists.isEmpty {
                MainTabView()
            } else if cloudSync?.status.hasCompletedInitialSync ?? true {
                LoginView()
            } else {
                CloudSyncLaunchView(onSkip: { cloudSync?.skipInitialSyncWait() })
            }
        }
        .task {
            if CommandLine.arguments.contains("-ui-testing") {
                seedTestPlaylist()
            }
        }
    }

    private func seedTestPlaylist() {
        guard playlists.isEmpty else { return }
        let playlist = Playlist(
            name: "Test Playlist",
            serverURL: "http://test.example.com:8080",
            username: "testuser",
            password: "testpass"
        )
        modelContext.insert(playlist)
        // Persist immediately so a separate ModelContext (e.g. the sync actor)
        // can see the seeded playlist without waiting for autosave.
        try? modelContext.save()
    }
}

#Preview("No Playlists") {
    ContentView()
}

#Preview("With Playlists") {
    ContentView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                container.mainContext.insert(playlist)
            }
        }
}
