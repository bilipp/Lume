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
    @AppStorage(OnboardingSettings.seenVersionKey) private var seenVersion = OnboardingSettings.seenVersionDefault

    /// True while the launch-time "Who's watching?" chooser is on screen. Shown
    /// eagerly when the setting is on (so the main UI never flashes first), then
    /// confirmed or dismissed once bootstrap resolves the profile roster.
    @State private var showStartupProfileChooser = false
    /// Latched once the chooser decision is final — either bootstrap resolved it
    /// or the user picked a profile. Stops the resolve pass from re-showing the
    /// chooser after the user has already dismissed it, and stops a later sync
    /// (which can bring in more profiles) from popping it mid-use.
    @State private var startupChoiceResolved = false

    /// True while the first-launch "How Lume Works" guide is on screen.
    @State private var showOnboarding = false
    /// Latched once the guide decision is final — bootstrap resolved it, or the
    /// user finished/skipped. Stops a later CloudKit import (which can flip the
    /// branches around this view) from re-presenting a guide already dismissed.
    @State private var onboardingResolved = false

    var body: some View {
        Group {
            // A populated local store always wins — returning users go straight
            // to the app. On an empty store we wait for the launch-time iCloud
            // sync to settle first, so cloud playlists aren't yanked in
            // mid-typing on a fresh device. If sync is unavailable, errors, or
            // times out, the gate opens and the guide (then the form) shows as a
            // fallback (see CloudSyncCoordinator).
            if !playlists.isEmpty {
                if showStartupProfileChooser {
                    ProfileSelectionView(onComplete: dismissStartupProfileChooser)
                } else {
                    MainTabView()
                }
            } else if cloudSync?.status.hasCompletedInitialSync ?? true {
                onboardingOrLogin
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
            showOnboardingEagerly()
        }
        .task(id: profileManager?.isReady) {
            resolveStartupProfileChooser()
            resolveOnboarding()
        }
    }

    /// The guide and the add-playlist form it hands off to. The guide is the
    /// launch chain's own screen here rather than a cover, but it still shows
    /// the first-launch copy: Skip, and a last page whose call to action hands
    /// off to the form.
    ///
    /// tvOS layers the two instead of swapping them, because a tvOS
    /// `fullScreenCover` always self-dismisses on Menu and the guide claims that
    /// button for itself (see `TVOnboardingOverlay`).
    @ViewBuilder
    private var onboardingOrLogin: some View {
        #if os(tvOS)
            LoginView()
                // tvOS focus is not clipped by z-order — the form under the
                // guide would still take remote presses.
                .disabled(showOnboarding)
                .overlay {
                    if showOnboarding {
                        TVOnboardingOverlay(isModal: true, onFinish: finishOnboarding)
                    }
                }
        #else
            if showOnboarding {
                OnboardingView(isModal: true, onFinish: finishOnboarding)
            } else {
                LoginView()
            }
        #endif
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

    /// Put the guide up on the stored version alone, before bootstrap has read
    /// the upgrade-suppression signal, so the add-playlist form never flashes
    /// ahead of it on a fresh install. The resolve pass below takes it back down
    /// if the signal turns out to say otherwise.
    private func showOnboardingEagerly() {
        guard !onboardingResolved else { return }
        showOnboarding = OnboardingSettings.needsOnboarding(
            seenVersion: seenVersion,
            isUITesting: isUITesting,
            hasPriorUsage: false
        )
    }

    /// Finalise the guide once bootstrap has resolved the profile roster, so the
    /// CloudKit-mirrored user state is readable. Runs once.
    private func resolveOnboarding() {
        guard !onboardingResolved, profileManager?.isReady == true else { return }
        onboardingResolved = true
        guard !isUITesting else {
            showOnboarding = false
            return
        }
        // Watch progress and profiles live in the cloud store (a separate
        // container the browse `@Query`s don't bind to); read the signal through
        // ProfileManager rather than the catalog env context.
        let hasPriorUsage = profileManager?.hasPriorUsage() ?? false
        // Seed the version so an upgrading user's guide stays retired even once
        // their catalog reads normally again.
        if hasPriorUsage, seenVersion < OnboardingSettings.currentVersion {
            seenVersion = OnboardingSettings.currentVersion
        }
        showOnboarding = OnboardingSettings.needsOnboarding(
            seenVersion: seenVersion,
            isUITesting: false,
            hasPriorUsage: hasPriorUsage
        )
    }

    private var isUITesting: Bool {
        CommandLine.arguments.contains("-ui-testing")
    }

    /// The user finished or skipped the guide — record the version so it stays
    /// down (it remains re-openable from Settings) and hand off to the form.
    private func finishOnboarding() {
        seenVersion = OnboardingSettings.currentVersion
        onboardingResolved = true
        showOnboarding = false
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
