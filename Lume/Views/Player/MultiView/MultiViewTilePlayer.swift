//
//  MultiViewTilePlayer.swift
//  Lume
//
//  Playback for one Multi-View tile: video only — no transport, no scrubber, no
//  Picture in Picture — plus the Stalker resolution and engine-fallback chain the
//  full-screen player uses. Every tile but the one carrying the audio plays
//  muted. The per-engine surfaces live in `MultiViewTilePlayer+Engines.swift`.
//

import OSLog
import SwiftData
import SwiftUI

struct MultiViewTilePlayer: View {
    let media: PlayableMedia
    let isMuted: Bool

    @Environment(\.modelContext) private var modelContext

    /// The user's ordered engine fallback list, resolved the same way the
    /// full-screen player resolves it, so a tile plays on the engine the viewer
    /// chose (and falls back identically when it can't open the stream).
    private let enginePriority: [PlayerEngineKind]

    /// Index into `enginePriority` of the engine driving this tile. Advanced when
    /// an engine can't start the stream.
    @State private var engineAttempt = 0
    /// Bumped by the retry affordance to rebuild the engine from scratch.
    @State private var reloadToken = 0
    /// The Stalker-resolved stand-in for `media` — see `FullScreenPlayerView`.
    /// `nil` while `create_link` is in flight; irrelevant for Xtream / m3u.
    @State private var resolvedMedia: PlayableMedia?
    @State private var resolveFailed = false
    /// True once the tile is rendering frames, which drops the spinner.
    @State private var isPlaying = false
    /// Set when every engine has been tried and none could open the stream.
    @State private var loadFailed = false

    /// A tile gets a shorter startup window than the full-screen player: the
    /// viewer is already watching another stream while it loads, so a dead one
    /// should hand off — or say so — promptly rather than hold a black rectangle.
    static let startupTimeout: TimeInterval = 25
    /// Startup window while another engine remains to try.
    static let fallbackStartupTimeout: TimeInterval = 12

    init(media: PlayableMedia, isMuted: Bool) {
        self.media = media
        self.isMuted = isMuted
        let defaults = UserDefaults.standard
        enginePriority = PlayerEnginePriority.resolve(
            priorityRaw: defaults.string(forKey: PlayerSettings.enginePriorityKey) ?? "",
            legacyEngineRaw: defaults.string(forKey: PlayerSettings.engineKey)
                ?? PlayerEngineKind.defaultValue.rawValue
        )
    }

    private var engine: PlayerEngineKind {
        guard enginePriority.indices.contains(engineAttempt) else { return .defaultValue }
        return enginePriority[engineAttempt]
    }

    private var hasFallbackEngine: Bool {
        engineAttempt + 1 < enginePriority.count
    }

    /// The stream to hand the engine — the resolved copy for a Stalker
    /// placeholder, gated on its identity matching the tile's current channel so
    /// a stale resolution never reaches the engine after a channel change.
    private var displayMedia: PlayableMedia? {
        guard StalkerLink.isPlaceholder(media.url) else { return media }
        guard let resolvedMedia, resolvedMedia.id == media.id else { return nil }
        return resolvedMedia
    }

    var body: some View {
        ZStack {
            Color.black

            if let displayMedia {
                engineView(for: displayMedia)
                    // The channel is part of the identity: switching channel has
                    // to tear the engine down and build a fresh one. Keyed on the
                    // engine alone, a switch reused the live engine view, which
                    // left the previous stream playing (the coordinators load in
                    // `onAppear`, and only KSPlayer reloads on a URL change) and
                    // stranded the spinner, because the tile had already latched
                    // "playback started" for the outgoing channel.
                    .id("\(engine.rawValue)-\(media.id)-\(reloadToken)")
            }

            if loadFailed || resolveFailed {
                failureBadge
            } else if !isPlaying {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .clipped()
        .task(id: "\(media.id)-\(reloadToken)") {
            await resolveIfNeeded()
        }
        .onChange(of: media.id) { _, _ in
            // A new channel in this tile restarts the fallback chain: the engine
            // the previous channel ended up on says nothing about this one. Every
            // outcome flag has to clear too, or the new channel inherits the old
            // one's spinner or failure badge.
            engineAttempt = 0
            isPlaying = false
            loadFailed = false
            resolveFailed = false
        }
    }

    @ViewBuilder
    private func engineView(for media: PlayableMedia) -> some View {
        switch engine {
        case .ksPlayer:
            MultiViewKSTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure
            )
        case .vlcKit:
            MultiViewVLCTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure
            )
        case .avPlayer:
            MultiViewAVTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure
            )
        case .lumeEngine:
            MultiViewLumeTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure
            )
        }
    }

    private var failureBadge: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
            Text("Stream unavailable")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Button("Try Again") { retry() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(.white)
        }
        .padding()
        .multilineTextAlignment(.center)
    }

    /// An engine couldn't open the stream: try the next one, or give up and show
    /// the retry affordance once the list is exhausted.
    private func handleFailure() {
        guard hasFallbackEngine else {
            loadFailed = true
            return
        }
        let failed = engine
        engineAttempt += 1
        Logger.player.log("multi-view: \(failed.rawValue, privacy: .public) could not start the tile; falling back to \(engine.rawValue, privacy: .public)")
    }

    private func retry() {
        engineAttempt = 0
        isPlaying = false
        loadFailed = false
        resolveFailed = false
        reloadToken += 1
    }

    /// Resolves a Stalker placeholder into a real (short-lived) stream URL before
    /// the engine loads it. A no-op for directly playable Xtream / m3u streams.
    private func resolveIfNeeded() async {
        guard StalkerLink.isPlaceholder(media.url) else { return }
        resolvedMedia = nil
        resolveFailed = false
        do {
            resolvedMedia = try await StalkerStreamResolver.resolve(media, container: modelContext.container)
        } catch {
            resolveFailed = true
            let detail = (error as? StalkerError)?.logDescription ?? LogRedaction.describe(error)
            Logger.player.error("multi-view: Stalker stream resolution failed: \(detail, privacy: .public)")
        }
    }
}
