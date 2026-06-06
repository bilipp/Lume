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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Playlist.self,
            Category.self,
            LiveStream.self,
            Movie.self,
            Series.self,
            Episode.self,
            CastMember.self,
            EPGListing.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // #if DEBUG
        //     // The schema is still in flux pre-release, so automatic lightweight
        //     // migration can leave the on-disk store in a state that traps at
        //     // save() time rather than at container creation (e.g. a newly added
        //     // Codable-collection attribute like `Movie.trailers`). A do/catch
        //     // around the init below can't recover from that, so instead we stamp
        //     // a schema version and wipe the store whenever it changes.
        //     //
        //     // Bump `schemaVersion` whenever you add/remove/retype a model property.
        //     let schemaVersion = 1
        //     let versionKey = "LumeDebugSchemaVersion"
        //     if UserDefaults.standard.integer(forKey: versionKey) != schemaVersion {
        //         Self.destroyStore(at: modelConfiguration.url)
        //         UserDefaults.standard.set(schemaVersion, forKey: versionKey)
        //     }
        // #endif

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            #if DEBUG
                // Init-time migration failure: wipe the store and retry once.
                Self.destroyStore(at: modelConfiguration.url)
                if let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
                    return container
                }
            #endif
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(TraktService.shared)
                .task {
                    // Restore a previously connected Trakt session (refreshing
                    // the token if stale) so watched-sync and the watchlist work
                    // from launch.
                    await TraktService.shared.restore()
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
