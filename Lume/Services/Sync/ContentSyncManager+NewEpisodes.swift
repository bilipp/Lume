import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// Checks all favorite Xtream series that have previously loaded episodes
    /// for new content from the provider. Sets `series.newEpisodesCount` to the
    /// number of episode IDs returned by the API that are not yet in the database.
    ///
    /// Only operates on Xtream playlists (M3U sources expose no episode API).
    /// Only series with at least one stored episode are checked — series that
    /// have never been opened have no baseline to compare against.
    ///
    /// This method is self-contained: it fetches everything it needs from its
    /// own ModelContext so callers don't need to pass SwiftData model objects
    /// across actor/concurrency boundaries.
    func scanFavoritesForNewEpisodes() async {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let xtreamRaw = PlaylistSourceType.xtream.rawValue
        let xtreamPlaylists = (try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.sourceTypeRaw == xtreamRaw })
        )) ?? []
        guard !xtreamPlaylists.isEmpty else { return }

        let favorites = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.isFavorite })
        )) ?? []
        let scannable = favorites.filter { !$0.episodes.isEmpty }

        guard !scannable.isEmpty else {
            Logger.database.info("New-episode scan: no favorite series with loaded episodes")
            return
        }

        Logger.database.info("New-episode scan: checking \(scannable.count) series")

        for series in scannable {
            guard let playlist = xtreamPlaylists.first(where: { series.id.hasPrefix($0.id.uuidString) }) else {
                continue
            }

            do {
                let parsed = try await fetchEpisodes(
                    seriesId: series.seriesId,
                    seriesElementId: series.id,
                    playlist: playlist
                )
                let existingIds = Set(series.episodes.map(\.id))
                let newCount = parsed.count(where: { !existingIds.contains($0.id) })
                if newCount > 0 {
                    series.newEpisodesCount = newCount
                    Logger.database.info("New-episode scan: \(newCount) new for '\(series.name)'")
                }
            } catch {
                Logger.database.warning("New-episode scan: failed for '\(series.name)': \(error)")
            }
        }

        try? context.save()
    }
}
