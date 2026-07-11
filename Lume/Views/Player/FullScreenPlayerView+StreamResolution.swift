//
//  FullScreenPlayerView+StreamResolution.swift
//  Lume
//
//  The player host's deferred-stream resolution: turning a Stalker/Stremio
//  placeholder into a playable URL, the Stremio source-picker flow, and the
//  parallel subtitle fetch. Split out of FullScreenPlayerView to keep that
//  file within the project's line-count cap.
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

extension FullScreenPlayerView {
    /// Resolves the active Stalker/Stremio placeholder into a playable URL. A
    /// no-op for directly playable streams. Re-runs whenever the active stream
    /// changes (open, channel surf, next episode), so each switch resolves a
    /// fresh, short-lived URL.
    func resolveActiveMedia() async {
        guard DeferredStreamLink.isPlaceholder(activeMedia.url) else { return }
        resolvedMedia = nil
        resolveError = nil
        streamOptions = nil
        subtitleFetch = nil
        do {
            if StremioLink.isPlaceholder(activeMedia.url), !activeMedia.isLive {
                // Subtitle tracks come from a different resource (and usually a
                // different addon) than the streams, so they fetch in parallel
                // and get attached when a stream is picked.
                let subtitleMedia = activeMedia
                let container = modelContext.container
                subtitleFetch = Task {
                    await StremioSubtitleResolver.subtitles(for: subtitleMedia, container: container)
                }
                // Stremio VOD: fetch every candidate so the viewer can choose
                // between qualities/sources. Live channels stay on the
                // first-playable path — a picker would break channel surfing.
                let options = try await StremioStreamResolver.streamOptions(
                    for: activeMedia, container: modelContext.container
                )
                guard !options.isEmpty else { throw StremioError.noStreamURL }
                if let auto = StremioStreamResolver.autoPick(
                    from: options,
                    matching: selectedBingeGroup,
                    askEnabled: PlayerSettings.Playback.stremioStreamPicker
                ) {
                    selectStreamOption(auto)
                } else {
                    streamOptions = options
                }
            } else {
                resolvedMedia = try await DeferredStreamLink.resolve(activeMedia, container: modelContext.container)
            }
        } catch {
            resolveError = error.localizedDescription
            let detail = (error as? StalkerError)?.logDescription ?? LogRedaction.describe(error)
            Logger.player.error("Stream resolution failed: \(detail, privacy: .public)")
        }
    }

    /// Starts playback with the chosen Stremio stream, remembering its binge
    /// group so subsequent episodes auto-continue on the same source. The
    /// stream's required request headers and any fetched subtitle tracks ride
    /// on the resolved media into the engine.
    func selectStreamOption(_ option: StremioStreamOption) {
        selectedBingeGroup = option.bingeGroup
        streamOptions = nil
        let target = activeMedia
        let fetch = subtitleFetch
        Task {
            let subtitles = await Self.awaitSubtitles(fetch)
            // The viewer may have surfed to another episode while the grace
            // period ran; a stale resolution must not reach the engine.
            guard target.id == activeMedia.id else { return }
            resolvedMedia = target.replacingURL(
                option.url,
                httpHeaders: option.headers,
                externalSubtitles: subtitles.isEmpty ? nil : subtitles
            )
        }
    }

    /// The fetched subtitle tracks, waiting at most `gracePeriod` on the
    /// in-flight fetch — playback start must not hang on a slow subtitle
    /// addon. Usually instant: the fetch ran while streams resolved (and while
    /// the viewer sat in the picker).
    private static func awaitSubtitles(
        _ fetch: Task<[ExternalSubtitle], Never>?,
        gracePeriod: TimeInterval = 3
    ) async -> [ExternalSubtitle] {
        guard let fetch else { return [] }
        return await withTaskGroup(of: [ExternalSubtitle].self) { group in
            group.addTask { await fetch.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(gracePeriod * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    func retryResolve() {
        engineAttempt = 0
        Task { await resolveActiveMedia() }
    }
}
