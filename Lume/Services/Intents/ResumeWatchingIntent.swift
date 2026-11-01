//
//  ResumeWatchingIntent.swift
//  Lume
//

import AppIntents
import Foundation
import SwiftData

nonisolated struct ResumeWatchingIntent: LumePlaybackIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Reopens the last thing you watched in Lume, where you left off.")

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    @Dependency private var catalog: ModelContainer
    @Dependency private var profiles: ProfileManager

    func perform() async throws -> some IntentResult {
        let link = try await IntentPlayback.resumeLink(catalog: catalog, profiles: profiles)
        try await openLume(playing: link)
        return .result()
    }
}
