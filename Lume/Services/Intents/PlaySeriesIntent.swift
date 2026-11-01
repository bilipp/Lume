//
//  PlaySeriesIntent.swift
//  Lume
//

import AppIntents
import Foundation
import SwiftData

nonisolated struct PlaySeriesIntent: LumePlaybackIntent {
    static let title: LocalizedStringResource = "Play Series"
    static let description = IntentDescription("Plays the next episode of a series in Lume, where you left off.")

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    @Parameter(title: "Series")
    var series: SeriesEntity

    @Dependency private var catalog: ModelContainer
    @Dependency private var profiles: ProfileManager

    func perform() async throws -> some IntentResult {
        try await play(series, parameter: $series, catalog: catalog, profiles: profiles)
    }
}
