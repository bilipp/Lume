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

/// What a tile is for. `.guidePreview` is the tvOS Guide's muted preview: a
/// shorter KSPlayer live buffer so the picture arrives sooner, an audio session
/// that mixes with other apps' audio where the engine lets the app choose one,
/// the channel logo instead of a Try Again button (the pane has no focusable
/// room for one), and `handle`, the seam full screen adopts its session through.
enum MultiViewTileRole {
    case multiView
    case guidePreview(handle: PreviewPlayerHandle?)

    /// Upper bound on KSPlayer's live forward buffer, in seconds; `nil` keeps
    /// the viewer's saved setting.
    var liveForwardBufferCap: TimeInterval? {
        isGuidePreview ? 1.5 : nil
    }

    var mixesWithOtherAudio: Bool {
        isGuidePreview
    }

    var showsRetry: Bool {
        !isGuidePreview
    }

    var logPrefix: String {
        isGuidePreview ? "guide-preview" : "multi-view"
    }

    var previewHandle: PreviewPlayerHandle? {
        guard case let .guidePreview(handle) = self else { return nil }
        return handle
    }

    /// False once the Guide preview's session belongs to full screen.
    var ownsSession: Bool {
        previewHandle.ownsSession
    }

    private var isGuidePreview: Bool {
        if case .guidePreview = self { true } else { false }
    }
}

struct MultiViewTilePlayer: View {
    let media: PlayableMedia
    let isMuted: Bool
    let role: MultiViewTileRole
    /// Fires once when the tile gives up: every engine failed, or the Stalker
    /// link could not be resolved.
    let onFailure: (() -> Void)?

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
    @State private var didReportFailure = false

    /// A tile gets a shorter startup window than the full-screen player: the
    /// viewer is already watching another stream while it loads, so a dead one
    /// should hand off — or say so — promptly rather than hold a black rectangle.
    static let startupTimeout: TimeInterval = 25
    /// Startup window while another engine remains to try.
    static let fallbackStartupTimeout: TimeInterval = 12

    init(
        media: PlayableMedia,
        isMuted: Bool,
        role: MultiViewTileRole = .multiView,
        onFailure: (() -> Void)? = nil
    ) {
        self.media = media
        self.isMuted = isMuted
        self.role = role
        self.onFailure = onFailure
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
            didReportFailure = false
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
                role: role,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure,
                sourceMedia: self.media
            )
        case .vlcKit:
            MultiViewVLCTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: hasFallbackEngine,
                role: role,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure,
                sourceMedia: self.media
            )
        case .avPlayer:
            MultiViewAVTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: hasFallbackEngine,
                role: role,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure,
                sourceMedia: self.media
            )
        case .lumeEngine:
            MultiViewLumeTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: hasFallbackEngine,
                role: role,
                onPlaybackStarted: { isPlaying = true },
                onPlaybackFailed: handleFailure,
                sourceMedia: self.media
            )
        }
    }

    private var failureBadge: some View {
        LiveChannelUnavailableBadge(
            logoURL: media.posterURL,
            logoSide: 80,
            onRetry: role.showsRetry ? { retry() } : nil
        )
        .padding()
    }

    /// An engine couldn't open the stream: try the next one, or give up and show
    /// the retry affordance once the list is exhausted.
    private func handleFailure() {
        guard hasFallbackEngine else {
            loadFailed = true
            reportFailure()
            return
        }
        let failed = engine
        engineAttempt += 1
        let prefix = role.logPrefix
        Logger.player.log("\(prefix, privacy: .public): \(failed.rawValue, privacy: .public) could not start the tile; falling back to \(engine.rawValue, privacy: .public)")
    }

    private func reportFailure() {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailure?()
    }

    private func retry() {
        engineAttempt = 0
        isPlaying = false
        loadFailed = false
        resolveFailed = false
        didReportFailure = false
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
            let prefix = role.logPrefix
            Logger.player.error("\(prefix, privacy: .public): Stalker stream resolution failed: \(detail, privacy: .public)")
            // A resolve cut short by a channel change is not the channel failing.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            reportFailure()
        }
    }
}
