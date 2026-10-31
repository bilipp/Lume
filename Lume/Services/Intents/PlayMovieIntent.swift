//
//  PlayMovieIntent.swift
//  Lume
//

import AppIntents
import Foundation
import SwiftData

nonisolated struct PlayMovieIntent: LumePlaybackIntent {
    static let title: LocalizedStringResource = "Play Movie"
    static let description = IntentDescription("Plays a movie in Lume, where you left off.")

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    @Parameter(title: "Movie")
    var movie: MovieEntity

    @Dependency private var catalog: ModelContainer
    @Dependency private var profiles: ProfileManager

    func perform() async throws -> some IntentResult {
        try await play(movie, parameter: $movie, catalog: catalog, profiles: profiles)
    }
}
