//
//  LumeShortcuts.swift
//  Lume
//

import AppIntents
import Foundation

nonisolated struct LumeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayChannelIntent(),
            phrases: [
                "Play \(\.$channel) in \(.applicationName)",
                "Watch \(\.$channel) in \(.applicationName)",
                "Play a channel in \(.applicationName)"
            ],
            shortTitle: "Play Channel",
            systemImageName: "tv"
        )
        AppShortcut(
            intent: PlayMovieIntent(),
            phrases: [
                "Start \(\.$movie) in \(.applicationName)",
                "Play \(\.$movie) in \(.applicationName)",
                "Start a movie in \(.applicationName)"
            ],
            shortTitle: "Play Movie",
            systemImageName: "film"
        )
        AppShortcut(
            intent: PlaySeriesIntent(),
            phrases: [
                "Play \(\.$series) in \(.applicationName)",
                "Continue \(\.$series) in \(.applicationName)",
                "Play a series in \(.applicationName)"
            ],
            shortTitle: "Play Series",
            systemImageName: "play.rectangle.on.rectangle"
        )
        AppShortcut(
            intent: ResumeWatchingIntent(),
            phrases: [
                "Continue watching in \(.applicationName)",
                "Resume watching in \(.applicationName)"
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle"
        )
    }
}

/// Coalesces the refreshes of the entity values Siri learns for the phrases
/// above: a sync or a run of favorite toggles asks many times, the system needs
/// it once.
@MainActor
enum LumeShortcutsRefresh {
    private static var pending: Task<Void, Never>?

    static func schedule() {
        guard !LumeApp.isTestOrPreviewHost else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            LumeShortcuts.updateAppShortcutParameters()
        }
    }
}
