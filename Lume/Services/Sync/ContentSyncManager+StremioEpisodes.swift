//
//  ContentSyncManager+StremioEpisodes.swift
//  Lume
//
//  On-demand episode loading for Stremio series (the series detail screen
//  calls `fetchStremioEpisodes` through `fetchEpisodes`), including the
//  meta-fallback chain used when the owning addon serves no `meta` resource.
//  Split out of ContentSyncManager+Stremio to keep that file within the
//  project's line-count cap.
//

import Foundation
import SwiftData

extension ContentSyncManager {
    /// Fetches a Stremio series' episodes on demand (the series detail screen
    /// calls this through `fetchEpisodes`). The series' full meta carries the
    /// episode list; each episode stores a placeholder link resolved at
    /// playback time. Episodes that haven't aired yet are skipped — they have
    /// no streams to resolve.
    ///
    /// Stream-focused addons (AIOStreams, Torrentio) serve catalogs and
    /// streams but no `meta` resource — in the Stremio app, Cinemeta fills
    /// that gap for IMDb-keyed titles. Mirror that: when the addon can't
    /// produce the meta and the id is IMDb-shaped, ask Cinemeta instead.
    func fetchStremioEpisodes(seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        let context = ModelContext(modelContainer)
        guard let stremioId = try context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesElementId })
        ).first?.stremioId else { return [] }

        let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))
        let meta: StremioMeta
        do {
            meta = try await client.getMeta(type: "series", id: stremioId).meta
        } catch {
            guard let fallback = await fallbackSeriesMeta(for: stremioId, excluding: playlist.id) else {
                throw error
            }
            meta = fallback
        }

        let now = Date()
        // Addons send `released` with and without fractional seconds; ISO8601
        // parsing is strict about the difference, so try both.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        var result: [ParsedEpisode] = []
        for (index, video) in (meta.videos ?? []).enumerated() {
            if let released = video.released,
               let releaseDate = fractional.date(from: released) ?? plain.date(from: released),
               releaseDate > now
            { continue }
            guard let placeholder = StremioLink.placeholder(type: "series", id: video.id) else { continue }
            result.append(ParsedEpisode(
                id: "\(seriesElementId)-episode-\(video.id)",
                episodeId: video.id,
                title: video.title ?? "",
                containerExtension: "mp4",
                seasonNum: video.season ?? 1,
                episodeNum: video.episode ?? index + 1,
                added: nil,
                directSource: placeholder.absoluteString,
                durationSecs: nil,
                movieImage: video.thumbnail,
                rating: nil,
                airDate: video.released,
                plot: video.overview
            ))
        }
        return result
    }

    /// A series meta from somewhere other than the owning addon, for when that
    /// addon can't produce one (stream-focused addons serve no `meta`
    /// resource). Mirrors the official app, where every installed addon is a
    /// candidate: Cinemeta is asked first for IMDb-keyed titles (it's the
    /// canonical source there), then the user's other Stremio playlists whose
    /// manifests declare series-meta support for the id's prefix — which is
    /// what makes e.g. a Kitsu playlist fill in episodes for anime ids that
    /// another addon's catalog surfaced. `nil` when no source can serve it.
    private func fallbackSeriesMeta(for stremioId: String, excluding playlistId: UUID) async -> StremioMeta? {
        if stremioId.hasPrefix("tt") {
            let cinemeta = StremioClient(
                configuration: StremioClient.Configuration(manifestURL: StremioClient.cinemetaManifestURL)
            )
            if let meta = try? await cinemeta.getMeta(type: "series", id: stremioId).meta {
                return meta
            }
        }

        let stremioRaw = PlaylistSourceType.stremio.rawValue
        let context = ModelContext(modelContainer)
        let others = (try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.sourceTypeRaw == stremioRaw && $0.id != playlistId })
        )) ?? []
        let prefix = StremioStreamResolver.idPrefix(of: stremioId)
        for playlist in others {
            let client = StremioClient(configuration: StremioClient.Configuration(playlist: playlist))
            guard let manifest = try? await client.getManifest(),
                  manifest.supports(resource: "meta", type: "series", idPrefix: prefix),
                  let meta = try? await client.getMeta(type: "series", id: stremioId).meta
            else { continue }
            return meta
        }
        return nil
    }
}
