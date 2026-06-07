//
//  TMDBLanguageWatcher.swift
//  Lume
//
//  Detects when the user's preferred language (system or per-app override)
//  changes between launches and invalidates cached TMDB enrichment so detail
//  views re-fetch text, videos and artwork in the new language.
//
//  There is deliberately no in-app language picker — Lume relies on the
//  per-app language override in iOS Settings, which relaunches the app when
//  changed, giving us a launch hook to react to.
//

import Foundation
import OSLog
import SwiftData

@MainActor
enum TMDBLanguageWatcher {
    private static let storedLanguageKey = "TMDBEnrichmentLanguage"
    private static let logger = Logger(subsystem: "com.lume", category: "TMDBLanguage")

    /// Clears `tmdbEnrichedAt` on every movie and series when the preferred
    /// TMDB language differs from the one previous enrichment ran with, so the
    /// content re-enriches lazily in the new language. A no-op on first launch
    /// and whenever the language is unchanged.
    static func invalidateEnrichmentIfLanguageChanged(in context: ModelContext) {
        let current = TMDBClient.preferredLanguageCode()
        let previous = UserDefaults.standard.string(forKey: storedLanguageKey)

        guard previous != current else { return }
        defer { UserDefaults.standard.set(current, forKey: storedLanguageKey) }

        // First launch: nothing has been enriched in another language yet, so
        // just record the language without forcing a needless re-fetch.
        guard previous != nil else { return }

        logger.info("Preferred language changed (\(previous ?? "nil") → \(current)); invalidating TMDB enrichment")
        resetEnrichment(in: context)
    }

    private static func resetEnrichment(in context: ModelContext) {
        do {
            let movies = try context.fetch(FetchDescriptor<Movie>())
            for movie in movies where movie.tmdbEnrichedAt != nil {
                movie.tmdbEnrichedAt = nil
            }
            let series = try context.fetch(FetchDescriptor<Series>())
            for show in series where show.tmdbEnrichedAt != nil {
                show.tmdbEnrichedAt = nil
            }
            try context.save()
        } catch {
            logger.error("Failed to invalidate TMDB enrichment: \(error.localizedDescription)")
        }
    }
}
