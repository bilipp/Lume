//
//  LumeApp.swift
//  Lume
//
//  Created by Philipp Bischoff on 09.04.26.
//

import OSLog
import SwiftData
import SwiftUI

@main
struct LumeApp: App {
    /// The CloudKit private-database container backing iCloud sync. Must match
    /// the id in `Lume.entitlements` and exist in the Apple Developer portal /
    /// CloudKit Console (schema deployed to Production before App Store release).
    static let cloudKitContainerIdentifier = "iCloud.bilipp.Lume"

    /// The local-only catalog store. The app's environment container — every
    /// browse `@Query` binds to it, so CloudKit's churn (which only touches the
    /// cloud store) can no longer invalidate it. This is the foreground-freeze fix.
    let catalogContainer: ModelContainer
    /// The CloudKit-mirrored user-data store. Only `CloudSyncEngine` and the
    /// profile views touch it.
    let cloudContainer: ModelContainer
    @State private var cloudSync: CloudSyncCoordinator
    @State private var profileManager: ProfileManager
    @State private var playlistSwitch = PlaylistSwitchModel()
    @State private var parentalControls: ParentalControls

    init() {
        let (catalog, cloud) = Self.makeModelContainers()
        catalogContainer = catalog
        cloudContainer = cloud
        let coordinator = CloudSyncCoordinator(
            catalogContainer: catalog,
            cloudContainer: cloud,
            cloudKitContainerIdentifier: Self.cloudKitContainerIdentifier,
            cloudKitEnabled: Self.isCloudKitEnvironment
        )
        _cloudSync = State(initialValue: coordinator)
        let profiles = ProfileManager(catalogContainer: catalog, cloudContainer: cloud, coordinator: coordinator)
        _profileManager = State(initialValue: profiles)
        _parentalControls = State(initialValue: ParentalControls(profileManager: profiles))
    }

    /// Builds **two separate containers** (the foreground-freeze fix):
    ///
    /// 1. `catalog` — a local-only store for the catalog (`Playlist`, `Movie`, …).
    ///    It is large, re-derivable from the provider, and uses `@Attribute(.unique)`
    ///    which CloudKit forbids — so it must NOT sync. Left unnamed to preserve the
    ///    existing on-disk `default.store`, so the upgrade doesn't strand users' data.
    /// 2. `cloud` — a CloudKit-synced store holding only the lightweight user-data
    ///    mirrors (`SyncedPlaylist`, `UserContentState`, `UserProfile`), reconciled
    ///    against the catalog by `CloudSyncEngine`.
    ///
    /// These were previously two *configurations* of one container. Splitting them
    /// into two containers gives the catalog its own `ModelContext` /
    /// `NSPersistentStoreCoordinator`, so `NSPersistentCloudKitContainer`'s
    /// continuous foreground import/export handshake (on the cloud store) no longer
    /// churns the catalog's `mainContext` — which is what re-evaluated every browse
    /// `@Query` dozens of times per foreground and pinned the main thread on tvOS.
    /// Both stores keep their existing files and schemas, so there is no migration.
    private static func makeModelContainers() -> (catalog: ModelContainer, cloud: ModelContainer) {
        let cloud = makeCloudContainer()
        let catalogSchema = Schema([
            Playlist.self, Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self
        ])
        // Unnamed → keeps the historical `default.store` path (preserves data).
        // `cloudKitDatabase: .none` is REQUIRED: the default is `.automatic`, which
        // mirrors the store to CloudKit whenever the binary is CloudKit-entitled. On
        // a properly-signed build that would force the catalog (with `@Attribute(.unique)`,
        // non-optional attributes and required relationships) into CloudKit and crash
        // at load (NSCocoaErrorDomain 134060). Tests/previews are un-entitled so
        // `.automatic` silently resolves to no-sync there — which is why this only
        // bites real builds. The catalog must stay strictly local.
        let catalogConfiguration = ModelConfiguration(
            schema: catalogSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        func buildCatalog() throws -> ModelContainer {
            try ModelContainer(for: catalogSchema, configurations: catalogConfiguration)
        }
        do {
            let catalog = try buildCatalog()
            // A `.syncing` status in the freshly opened store is stale by
            // definition — its owning task died with the previous process. Reset
            // it now, before MainTabView's auto-sync gate reads playlist status,
            // or the playlist stays wedged out of all future syncs.
            ContentSyncManager.recoverInterruptedSyncs(in: ModelContext(catalog))
            return (catalog, cloud)
        } catch {
            #if DEBUG
                // Init-time migration failure: wipe the local catalog store and
                // retry once. The cloud store is CloudKit-backed and re-hydrates,
                // and the reconcile engine's empty-store recovery (CloudSyncEngine's
                // `LocalCatalogReadiness`) pulls the catalog back rather than
                // pushing the now-empty store's "deletions" to iCloud. Logged
                // loudly so a destructive local wipe is never silent.
                Logger.sync.error("Local catalog store load failed (\(error.localizedDescription, privacy: .public)) — DEBUG: wiping default.store and retrying once")
                destroyStore(at: catalogConfiguration.url)
                if let catalog = try? buildCatalog() {
                    return (catalog, cloud)
                }
            #endif
            fatalError("Could not create catalog ModelContainer: \(error)")
        }
    }

    /// The CloudKit-mirrored user-data container (`SyncedPlaylist`,
    /// `UserContentState`, `UserProfile`). Small and CloudKit-backed; a load
    /// failure is unexpected, so fail loudly rather than risk a silent empty store.
    private static func makeCloudContainer() -> ModelContainer {
        let cloudSchema = Schema([SyncedPlaylist.self, UserContentState.self, UserProfile.self])
        let cloudConfiguration = ModelConfiguration(
            "CloudUserData",
            schema: cloudSchema,
            cloudKitDatabase: cloudKitDatabase
        )
        do {
            return try ModelContainer(for: cloudSchema, configurations: cloudConfiguration)
        } catch {
            fatalError("Could not create cloud ModelContainer: \(error)")
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
                .environment(PremiumManager.shared)
                .environment(cloudSync)
                .environment(profileManager)
                .environment(playlistSwitch)
                .environment(parentalControls)
                .task {
                    // Give DownloadManager access to the model container so it
                    // can persist download state from its delegate callbacks.
                    #if !os(tvOS)
                        DownloadManager.shared.configure(container: catalogContainer)
                    #endif

                    // Commit any watch progress that a previous session buffered
                    // but never flushed to SwiftData (e.g. it was killed mid-
                    // playback). Runs off the main thread before playback starts.
                    await WatchProgressWriter.reconcilePending(container: catalogContainer)

                    // If the preferred language changed since last launch (e.g.
                    // via the per-app language override in iOS Settings), drop
                    // cached TMDB enrichment so detail views re-fetch text,
                    // videos and artwork in the new language.
                    TMDBLanguageWatcher.invalidateEnrichmentIfLanguageChanged(
                        in: catalogContainer.mainContext
                    )

                    // Restore a previously connected Trakt session (refreshing
                    // the token if stale) so watched-sync and the watchlist work
                    // from launch.
                    await TraktService.shared.restore()

                    // Resolve the active profile and claim any pre-profiles
                    // content state before the first sync, so the catalog the
                    // reconciler reads is already scoped to a profile.
                    await profileManager.bootstrap()

                    // Kick off iCloud sync: check account reachability, then run
                    // a first reconcile between the local catalog and the cloud
                    // mirrors. Runs after progress reconciliation so a fresh
                    // device's user state lands on a settled local store.
                    await cloudSync.start()

                    // Resume background content indexing for anything still
                    // unindexed (the pass waits on its own while a playlist
                    // sync is running).
                    ContentIndexingService.shared.configure(container: catalogContainer)
                    ContentIndexingService.shared.kick()
                }
                .onChange(of: scenePhase) { _, phase in
                    cloudSync.handleScenePhaseChange(to: phase)
                }
        }
        .modelContainer(catalogContainer)

        #if os(macOS)
            WindowGroup(id: "player", for: PlayableMedia.self) { $media in
                if let media {
                    FullScreenPlayerView(media: media)
                        .frame(minWidth: 800, minHeight: 450)
                }
            }
            .modelContainer(catalogContainer)
            .environment(TraktService.shared)
            .environment(PremiumManager.shared)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
        #endif
    }
}
