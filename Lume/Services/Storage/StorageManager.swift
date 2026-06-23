//
//  StorageManager.swift
//  Lume
//
//  Backs the Storage & Cache settings screen: it gathers the catalog item
//  counts and on-disk figures (the local catalog store and the image cache),
//  and performs the clear operations.
//
//  Everything the user can clear here is re-derivable: image artwork
//  re-downloads on demand and TMDB/OMDb enrichment is re-fetched the next time
//  a title's detail screen opens. Playlists, downloads, watch history and
//  favorites live in separate stores and are never touched.
//

import Foundation
import OSLog
import SwiftData

/// A snapshot of how much content is stored and how much disk it occupies.
struct StorageStats {
    var movieCount: Int
    var seriesCount: Int
    var episodeCount: Int
    var channelCount: Int
    /// Bytes of the local catalog SQLite store (plus its WAL/SHM sidecars).
    var catalogBytes: Int64
    /// Bytes of the on-disk image cache directory.
    var imageCacheBytes: Int64
}

@MainActor
enum StorageManager {
    private static let logger = Logger(subsystem: "com.lume", category: "Storage")

    // MARK: - Stats

    /// Counts the catalog (cheap SQLite `COUNT` queries on the main context) and
    /// sums the on-disk sizes off the main actor.
    static func gatherStats(in context: ModelContext) async -> StorageStats {
        let movieCount = (try? context.fetchCount(FetchDescriptor<Movie>())) ?? 0
        let seriesCount = (try? context.fetchCount(FetchDescriptor<Series>())) ?? 0
        let episodeCount = (try? context.fetchCount(FetchDescriptor<Episode>())) ?? 0
        let channelCount = (try? context.fetchCount(FetchDescriptor<LiveStream>())) ?? 0

        let storeURL = catalogStoreURL(for: context)
        let imageDirectory = ImageDiskCache.shared.directoryURL
        let (catalogBytes, imageCacheBytes) = await Task.detached {
            (storeURL.map(storeSize(at:)) ?? 0, directorySize(imageDirectory))
        }.value

        return StorageStats(
            movieCount: movieCount,
            seriesCount: seriesCount,
            episodeCount: episodeCount,
            channelCount: channelCount,
            catalogBytes: catalogBytes,
            imageCacheBytes: imageCacheBytes
        )
    }

    // MARK: - Clearing

    /// Empties both tiers of the image cache. The disk removal runs off the main
    /// actor; `NSCache` is thread-safe so the memory tier clears inline.
    static func clearImageCache() async {
        ImageMemoryCache.shared.removeAll()
        await Task.detached {
            ImageDiskCache.shared.removeAll()
        }.value
    }

    /// Drops cached TMDB/OMDb enrichment (artwork paths, cast, trailers, ratings
    /// and collection info) from every enriched movie and series so it re-fetches
    /// lazily on the next detail-screen visit. Runs on the passed-in (main)
    /// context — like `TMDBLanguageWatcher` — so browse views reflect the cleared
    /// artwork immediately rather than after a relaunch.
    static func clearMetadataEnrichment(in context: ModelContext) {
        do {
            // Filter in SQLite so only already-enriched rows are hydrated.
            let movies = try context.fetch(FetchDescriptor<Movie>(
                predicate: #Predicate { $0.tmdbEnrichedAt != nil || $0.ratingsEnrichedAt != nil }
            ))
            for movie in movies {
                // Clearing the relationship array only disassociates the rows;
                // delete them explicitly so the orphaned cast doesn't linger and
                // keep occupying the store.
                for cast in movie.castMembers {
                    context.delete(cast)
                }
                movie.backdropPath = nil
                movie.logoPath = nil
                movie.tagline = nil
                movie.contentRating = nil
                movie.tmdbEnrichedAt = nil
                movie.similarTMDBIds = []
                movie.trailersData = nil
                movie.imdbId = nil
                movie.externalRatingsData = nil
                movie.ratingsEnrichedAt = nil
                movie.collectionId = nil
                movie.collectionName = nil
                movie.collectionPosterPath = nil
                movie.collectionBackdropPath = nil
            }

            let series = try context.fetch(FetchDescriptor<Series>(
                predicate: #Predicate { $0.tmdbEnrichedAt != nil || $0.ratingsEnrichedAt != nil }
            ))
            for show in series {
                for cast in show.castMembers {
                    context.delete(cast)
                }
                show.backdropPath = nil
                show.logoPath = nil
                show.tagline = nil
                show.contentRating = nil
                show.tmdbEnrichedAt = nil
                show.similarTMDBIds = []
                show.trailersData = nil
                show.imdbId = nil
                show.externalRatingsData = nil
                show.ratingsEnrichedAt = nil
            }

            try context.save()
        } catch {
            logger.error("Failed to clear metadata enrichment: \(error.localizedDescription)")
        }
    }

    /// Wipes the active profile's watch history: resets `watchProgress`,
    /// `isWatched` and `lastWatchedDate` on every movie and episode, and clears
    /// `lastWatchedDate` on every series and channel. Favorites, watchlist and
    /// recommendation votes are left untouched.
    ///
    /// Runs on the passed-in (main) context — like `clearMetadataEnrichment` —
    /// so the Continue Watching / Recently Watched rows update immediately. The
    /// iCloud reconciler picks up the cleared local state on its next pass and
    /// mirrors the reset to CloudKit (and thus the user's other devices), the
    /// same way an individual "remove from recently watched" does. The
    /// `#Predicate` filters keep only rows that actually carry watch state out of
    /// the fetch, so an untouched catalog isn't hydrated wholesale.
    static func clearWatchHistory(in context: ModelContext) {
        do {
            let movies = try context.fetch(FetchDescriptor<Movie>(
                predicate: #Predicate { $0.watchProgress != 0 || $0.isWatched || $0.lastWatchedDate != nil }
            ))
            for movie in movies {
                movie.watchProgress = 0
                movie.isWatched = false
                movie.lastWatchedDate = nil
            }

            let episodes = try context.fetch(FetchDescriptor<Episode>(
                predicate: #Predicate { $0.watchProgress != 0 || $0.isWatched || $0.lastWatchedDate != nil }
            ))
            for episode in episodes {
                episode.watchProgress = 0
                episode.isWatched = false
                episode.lastWatchedDate = nil
            }

            let series = try context.fetch(FetchDescriptor<Series>(
                predicate: #Predicate { $0.lastWatchedDate != nil }
            ))
            for show in series {
                show.lastWatchedDate = nil
            }

            let channels = try context.fetch(FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.lastWatchedDate != nil }
            ))
            for channel in channels {
                channel.lastWatchedDate = nil
            }

            try context.save()
        } catch {
            logger.error("Failed to clear watch history: \(error.localizedDescription)")
        }
    }

    #if DEBUG
        /// DEBUG-only: wipes the on-device search index end to end — the TMDB/OMDb
        /// enrichment (via `clearMetadataEnrichment`), the embedding vectors, the
        /// resolved `tmdbId` links and each title's `indexedAt` stamp — so the
        /// next indexing pass rebuilds everything from scratch. Used to exercise
        /// the indexer during development.
        static func clearIndex(in context: ModelContext) {
            clearMetadataEnrichment(in: context)
            do {
                let movies = try context.fetch(FetchDescriptor<Movie>(
                    predicate: #Predicate { $0.indexedAt != nil || $0.embeddingData != nil || $0.tmdbId != nil }
                ))
                for movie in movies {
                    movie.tmdbId = nil
                    movie.embeddingData = nil
                    movie.indexedAt = nil
                }

                let series = try context.fetch(FetchDescriptor<Series>(
                    predicate: #Predicate { $0.indexedAt != nil || $0.embeddingData != nil || $0.tmdbId != nil }
                ))
                for show in series {
                    show.tmdbId = nil
                    show.embeddingData = nil
                    show.indexedAt = nil
                }

                try context.save()
            } catch {
                logger.error("Failed to clear index: \(error.localizedDescription)")
            }
        }
    #endif

    // MARK: - Disk sizing (off the main actor)

    /// The URL of the local catalog store (the configuration that isn't the
    /// CloudKit user-data store).
    private static func catalogStoreURL(for context: ModelContext) -> URL? {
        context.container.configurations.first { $0.name != "CloudUserData" }?.url
    }

    /// Total bytes of a SQLite store including its `-wal`/`-shm` sidecar files.
    nonisolated static func storeSize(at storeURL: URL) -> Int64 {
        [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"]
            .reduce(0) { $0 + fileSize(atPath: $1) }
    }

    /// Sum of the sizes of every regular file under `url`.
    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private nonisolated static func fileSize(atPath path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? Int64) ?? 0
    }
}
