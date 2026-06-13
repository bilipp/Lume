//
//  LumeApp.swift
//  Lume
//
//  Created by Philipp Bischoff on 09.04.26.
//

import SwiftData
import SwiftUI

@main
struct LumeApp: App {
    /// The CloudKit private-database container backing iCloud sync. Must match
    /// the id in `Lume.entitlements` and exist in the Apple Developer portal /
    /// CloudKit Console (schema deployed to Production before App Store release).
    static let cloudKitContainerIdentifier = "iCloud.bilipp.Lume"

    let sharedModelContainer: ModelContainer
    @State private var cloudSync: CloudSyncCoordinator

    init() {
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        _cloudSync = State(initialValue: CloudSyncCoordinator(
            container: container,
            cloudKitContainerIdentifier: Self.cloudKitContainerIdentifier,
            cloudKitEnabled: Self.isCloudKitEnvironment
        ))
    }

    /// Builds the container with **two configurations**:
    ///
    /// 1. A local-only store for the catalog (`Playlist`, `Movie`, …). It is
    ///    large, re-derivable from the provider, and uses `@Attribute(.unique)`
    ///    which CloudKit forbids — so it must NOT sync. This configuration is
    ///    left unnamed to preserve the existing on-disk `default.store`, so the
    ///    upgrade doesn't strand current users' data.
    /// 2. A CloudKit-synced store holding only the lightweight user-data mirrors
    ///    (`SyncedPlaylist`, `UserContentState`), reconciled against the catalog
    ///    by `CloudSyncEngine`.
    private static func makeModelContainer() -> ModelContainer {
        let localSchema = Schema([
            Playlist.self,
            Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            CastMember.self,
            EPGListing.self
        ])
        let cloudSchema = Schema([
            SyncedPlaylist.self,
            UserContentState.self
        ])
        let fullSchema = Schema([
            Playlist.self, Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self,
            SyncedPlaylist.self, UserContentState.self
        ])

        // Unnamed → keeps the historical `default.store` path (preserves data).
        let localConfiguration = ModelConfiguration(schema: localSchema, isStoredInMemoryOnly: false)
        let cloudConfiguration = ModelConfiguration(
            "CloudUserData",
            schema: cloudSchema,
            cloudKitDatabase: cloudKitDatabase
        )

        func build() throws -> ModelContainer {
            try ModelContainer(for: fullSchema, configurations: localConfiguration, cloudConfiguration)
        }

        do {
            let container = try build()
            // A `.syncing` status in the freshly opened store is stale by
            // definition — its owning task died with the previous process. Reset
            // it now, before MainTabView's auto-sync gate reads playlist status,
            // or the playlist stays wedged out of all future syncs.
            ContentSyncManager.recoverInterruptedSyncs(in: ModelContext(container))
            return container
        } catch {
            #if DEBUG
                // Init-time migration failure: wipe the local store and retry
                // once. The cloud store is CloudKit-backed and re-hydrates.
                destroyStore(at: localConfiguration.url)
                if let container = try? build() {
                    return container
                }
            #endif
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// Whether the running binary can use CloudKit at all.
    ///
    /// `NSPersistentCloudKitContainer` hard-crashes on a background queue (an
    /// un-catchable `_os_crash` in `containerWithIdentifier:`) when the binary
    /// isn't entitled for the container — which is the case under SwiftUI
    /// previews and `xcodebuild test`/UI-test runs (ad-hoc "Sign to Run Locally",
    /// no CloudKit provisioning). Likewise `CKContainer(identifier:)` raises on an
    /// un-entitled id. In those contexts we skip CloudKit entirely: the user-data
    /// store stays local and the reconcile engine still runs (just no sync).
    /// Real, properly-signed builds get full CloudKit sync.
    static let isCloudKitEnvironment: Bool = {
        let environment = ProcessInfo.processInfo.environment
        let isPreview = environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let isUnitTest = environment["XCTestConfigurationFilePath"] != nil
        let isUITest = CommandLine.arguments.contains("-ui-testing")
        return !(isPreview || isUnitTest || isUITest)
    }()

    private static var cloudKitDatabase: ModelConfiguration.CloudKitDatabase {
        isCloudKitEnvironment ? .private(cloudKitContainerIdentifier) : .none
    }

    #if DEBUG
        /// Deletes the SwiftData store and its WAL/SHM sidecar files so the next
        /// `ModelContainer` init starts from a clean schema. Debug-only.
        private static func destroyStore(at url: URL) {
            let fileManager = FileManager.default
            for path in [url.path, url.path + "-shm", url.path + "-wal"] where fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    #endif

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(TraktService.shared)
                .environment(cloudSync)
                .task {
                    // Give DownloadManager access to the model container so it
                    // can persist download state from its delegate callbacks.
                    #if !os(tvOS)
                        DownloadManager.shared.configure(container: sharedModelContainer)
                    #endif

                    // Commit any watch progress that a previous session buffered
                    // but never flushed to SwiftData (e.g. it was killed mid-
                    // playback). Runs off the main thread before playback starts.
                    await WatchProgressWriter.reconcilePending(container: sharedModelContainer)

                    // If the preferred language changed since last launch (e.g.
                    // via the per-app language override in iOS Settings), drop
                    // cached TMDB enrichment so detail views re-fetch text,
                    // videos and artwork in the new language.
                    TMDBLanguageWatcher.invalidateEnrichmentIfLanguageChanged(
                        in: sharedModelContainer.mainContext
                    )

                    // Restore a previously connected Trakt session (refreshing
                    // the token if stale) so watched-sync and the watchlist work
                    // from launch.
                    await TraktService.shared.restore()

                    // Kick off iCloud sync: check account reachability, then run
                    // a first reconcile between the local catalog and the cloud
                    // mirrors. Runs after progress reconciliation so a fresh
                    // device's user state lands on a settled local store.
                    await cloudSync.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    cloudSync.handleScenePhaseChange(to: phase)
                }
        }
        .modelContainer(sharedModelContainer)

        #if os(macOS)
            WindowGroup(id: "player", for: PlayableMedia.self) { $media in
                if let media {
                    FullScreenPlayerView(media: media)
                        .frame(minWidth: 800, minHeight: 450)
                }
            }
            .modelContainer(sharedModelContainer)
            .environment(TraktService.shared)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
        #endif
    }
}
