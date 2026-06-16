import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    /// Optional so previews (which don't inject the coordinator) don't crash;
    /// a missing coordinator reads as "gate open", preserving old behaviour.
    @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
    // Optional for the same reason — previews don't inject a ProfileManager.
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query private var playlists: [Playlist]

    @AppStorage(ProfileSettings.askOnStartupKey) private var askOnStartup = ProfileSettings.askOnStartupDefault

    /// True while the launch-time "Who's watching?" chooser is on screen. Shown
    /// eagerly when the setting is on (so the main UI never flashes first), then
    /// confirmed or dismissed once bootstrap resolves the profile roster.
    @State private var showStartupProfileChooser = false
    /// Latched once the chooser decision is final — either bootstrap resolved it
    /// or the user picked a profile. Stops the resolve pass from re-showing the
    /// chooser after the user has already dismissed it, and stops a later sync
    /// (which can bring in more profiles) from popping it mid-use.
    @State private var startupChoiceResolved = false

    var body: some View {
        Group {
            // A populated local store always wins — returning users go straight
            // to the app. On an empty store we wait for the launch-time iCloud
            // sync to settle first, so cloud playlists aren't yanked in
            // mid-typing on a fresh device. If sync is unavailable, errors, or
            // times out, the gate opens and the form shows as a fallback (see
            // CloudSyncCoordinator).
            if !playlists.isEmpty {
                if showStartupProfileChooser {
                    ProfileSelectionView(onComplete: dismissStartupProfileChooser)
                } else {
                    MainTabView()
                }
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
        .onAppear {
            // Put the chooser up immediately for opt-in users so the main UI
            // doesn't flash before bootstrap finishes; the resolve pass below
            // takes it back down if it turns out there's nothing to choose.
            if askOnStartup, !startupChoiceResolved {
                showStartupProfileChooser = true
            }
        }
        .task(id: profileManager?.isReady) {
            resolveStartupProfileChooser()
        }
    }

    /// Finalise the startup chooser once bootstrap has resolved the profile
    /// roster: keep it up only if asked-on-startup is on and there's more than
    /// one profile to pick from, otherwise drop straight into the app. Runs once.
    private func resolveStartupProfileChooser() {
        guard !startupChoiceResolved, profileManager?.isReady == true else { return }
        startupChoiceResolved = true
        // UserProfile lives in the cloud store (a separate container); read the
        // count through ProfileManager rather than the catalog env context.
        let profileCount = profileManager?.allProfiles().count ?? 0
        showStartupProfileChooser = askOnStartup && profileCount > 1
    }

    /// The user picked a profile — go to the app and latch the decision so the
    /// resolve pass can't bring the chooser back.
    private func dismissStartupProfileChooser() {
        startupChoiceResolved = true
        showStartupProfileChooser = false
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
