//
//  PlayChannelIntent.swift
//  Lume
//

import AppIntents
import Foundation
import SwiftData

nonisolated struct PlayChannelIntent: LumePlaybackIntent {
    static let title: LocalizedStringResource = "Play Channel"
    static let description = IntentDescription("Plays a live TV channel in Lume.")

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    @Parameter(title: "Channel")
    var channel: ChannelEntity

    @Dependency private var catalog: ModelContainer
    @Dependency private var profiles: ProfileManager

    func perform() async throws -> some IntentResult {
        try await play(channel, parameter: $channel, catalog: catalog, profiles: profiles)
    }
}
