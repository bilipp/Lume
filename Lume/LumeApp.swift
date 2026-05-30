//
//  LumeApp.swift
//  Lume
//
//  Created by Philipp Bischoff on 09.04.26.
//

import SwiftUI
import SwiftData

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
            EPGListing.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #endif
    }
}
