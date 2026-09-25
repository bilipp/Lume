import OSLog
import SwiftData
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Top-level full-screen video host. Picks the engine implementation based on
/// the user setting, owns progress state, and persists watch progress back
/// into SwiftData for VOD content.
struct FullScreenPlayerView: View {
    let media: PlayableMedia

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Optional so previews (which don't inject it) don't crash.
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    /// This player's own playback-health bracket. Per view, not per tracker:
    /// macOS opens the player in its own window and iPadOS can run several
    /// scenes, so two sessions can be in flight at once.
    @State var healthToken: PlaybackHealthTracker.Token?
    /// The in-flight progress write, so the review policy can wait for a
    /// finished title to be counted before it judges the session that
    /// finished it.
    @State var pendingProgressWrite: Task<Void, Never>?
    /// The stream an explicit "next episode" already settled at full duration.
    /// The swap that follows immediately flushes progress, and that flush would
    /// otherwise record the position the viewer skipped from and undo the
    /// completion. Non-private so `completeActiveEpisode` in
    /// `FullScreenPlayerView+Navigation` can claim the ref before swapping.
    @State var completedRef: PlayableMedia.ContentRef?
    #if os(macOS)
        @Environment(\.dismissWindow) private var dismissWindow
    #endif

    /// The user's ordered engine fallback list, read once when the player opens.
    /// Settings changes don't reshuffle a session already in flight; reopening
    /// the player picks up the new order. See `PlayerEnginePriority`.
    private let enginePriority: [PlayerEngineKind]

    /// Index into `enginePriority` of the engine currently driving playback.
    /// Advanced when an engine fails to start a stream, falling the player back
    /// to the next engine in the list. Reset to the primary engine whenever the
    /// active stream changes.
    /// Non-private so the swap path in `FullScreenPlayerView+Navigation` can
    /// restart the fallback chain for a newly selected stream.
    @State var engineAttempt = 0

    /// Observes the active AirPlay route. Full-screen AirPlay *video* is only
    /// possible through `AVPlayer` (KSPlayer/VLCKit render into their own layers,
    /// so AirPlay would carry only their audio), so while a route is active the
    /// stream is driven through the AVPlayer engine regardless of the user's
    /// engine preference. See `engine` / `castService`.
    @State private var castService = CastService.shared

    /// Ids of streams AVPlayer couldn't start while casting over AirPlay (a codec
    /// or container AVPlayer can't open — common for MPEG-TS / MKV IPTV that only
    /// KSPlayer/VLCKit handle). Once a stream is in here the AirPlay-forces-AVPlayer
    /// override is dropped for it, so it plays on the user's engine locally with
    /// the audio still on the receiver, instead of a dead "stream offline" error.
    /// A set, not one id, because in-player stepping comes back: surfing away
    /// from an uncastable channel and back must not re-run the failed AVPlayer
    /// attempt. Cleared only when the route goes away — a different receiver may
    /// well handle what this one couldn't.
    @State private var airPlayVideoUnsupported: Set<String> = []

    /// The only high-frequency playback state. An `@Observable` the host owns
    /// but never reads in its own body, so playback ticks invalidate just the
    /// scrubber/time labels rather than re-rendering the whole player tree. See
    /// `PlaybackClock`.
    @State var clock = PlaybackClock()

    /// Writes watch progress on a private background `ModelContext`. Saving on
    /// the main context mid-playback hitches KSPlayer's render loop, so the
    /// sampler below only reads the clock and hands `Sendable` values to this
    /// actor. Created in `.task` once the environment's container is available.
    /// Non-private so the explicit-finish path in `FullScreenPlayerView+Navigation`
    /// can write through the same actor rather than opening a second context.
    @State var progressWriter: WatchProgressWriter?

    /// The stream currently playing. Starts as `media` but can be swapped when
    /// the viewer picks another episode from the in-player episode rail (tvOS).
    @State var activeMedia: PlayableMedia

    /// The Stalker-resolved stand-in for `activeMedia`. Stalker streams arrive as
    /// a `lumestalker://` placeholder whose real URL is fetched via `create_link`
    /// at playback time; this holds the resolved copy once it lands. `nil` while
    /// resolution is in flight (the loading indicator shows). Engines that play a
    /// directly usable URL (Xtream / m3u) bypass this entirely — see `displayMedia`.
    @State var resolvedMedia: PlayableMedia?

    /// Set when Stalker `create_link` resolution fails, so the host shows the
    /// failure overlay instead of an endless spinner.
    @State private var resolveError: String?

    /// The episode queued to play after `activeMedia`, resolved whenever the
    /// active stream changes. Drives both the in-player Next Episode button and
    /// auto-advance (see `PlayerNextUpOverlay`); `nil` for movies, live channels
    /// and series finales. Read only when the player tree is (re)built, never on
    /// the per-tick clock path.
    @State private var nextUpMedia: PlayableMedia?

    /// Intro / recap / outro windows for the active episode (from IntroDB). The
    /// openers drive the in-player Skip Intro button; the outro sets when the
    /// Next Episode button arms. `nil` for movies, live channels, and episodes
    /// IntroDB doesn't know — resolved whenever the active stream changes. Read
    /// only when the player tree is (re)built, never on the per-tick clock path.
    /// See `PlayerSkipIntroOverlay` / `PlayerNextUpOverlay`.
    @State private var skipSegments: IntroSegments?

    /// What the previous/next transport controls play for the active stream.
    /// Resolved once per stream in `.task(id:)` below, never in a body and never
    /// on the per-tick clock path. Non-private so the lock-screen hook in
    /// `FullScreenPlayerView+Navigation` reads the same answer the on-screen
    /// controls do. See `FullScreenPlayerView+Navigation`.
    @State var itemNeighbours = PlayerItemNavigation.Neighbours.none

    /// Serialises every in-player stream change for this session, whichever
    /// surface asked: the transport buttons, a macOS arrow key, the Siri Remote,
    /// or the lock screen / Control Center / a headset's track buttons.
    ///
    /// One per player, threaded down to the engine view, rather than one per
    /// surface — the cooldown exists to keep two decoder teardowns from being in
    /// flight, and a swapper each would let a lock-screen press and an on-screen
    /// press start one apiece inside the same 0.3 s. Not static either: iPadOS
    /// can run several player scenes, which are genuinely independent.
    @State var mediaSwapper = PlayerMediaSwapper()

    /// The sort the viewer's channel list was in, and what they may watch. Read
    /// in the host, not in each engine view: neighbours resolve once per stream.
    @AppStorage(SortStorageKey.liveContent)
    private var liveContentSortRaw: String = ContentSortOption.playlist.rawValue
    @Environment(\.contentRestriction) private var contentRestriction

    init(media: PlayableMedia) {
        self.media = media
        _activeMedia = State(initialValue: media)
        let defaults = UserDefaults.standard
        enginePriority = PlayerEnginePriority.resolve(
            priorityRaw: defaults.string(forKey: PlayerSettings.enginePriorityKey) ?? "",
            legacyEngineRaw: defaults.string(forKey: PlayerSettings.engineKey)
                ?? PlayerEngineKind.defaultValue.rawValue
        )
    }

    /// The engine the user's priority list selects for the current attempt,
    /// before any AirPlay override.
    private var priorityEngine: PlayerEngineKind {
        guard enginePriority.indices.contains(engineAttempt) else { return .defaultValue }
        return enginePriority[engineAttempt]
    }

    /// The engine driving the current playback attempt. While an AirPlay route is
    /// active, this forces `.avPlayer` — the only engine that can hand full-screen
    /// video to an AirPlay receiver (see `castService`).
    private var engine: PlayerEngineKind {
        isAirPlayOverride ? .avPlayer : priorityEngine
    }

    /// True when AirPlay is active and the user's engine isn't already AVPlayer,
    /// so the stream is being force-routed through AVPlayer for the cast. Drops
    /// back to the user's engine once AVPlayer has proven it can't play the
    /// current stream (`airPlayVideoUnsupported`).
    private var isAirPlayOverride: Bool {
        castService.isAirPlayActive
            && priorityEngine != .avPlayer
            && !airPlayVideoUnsupported.contains(activeMedia.id)
    }

    /// Whether another engine remains to fall back to after the current one.
    /// Suppressed during an AirPlay override: the forced AVPlayer either casts or
    /// shows its error overlay, rather than looping through the fallback chain
    /// (which would only land back on engines that can't cast video).
    private var hasFallbackEngine: Bool {
        !isAirPlayOverride && engineAttempt + 1 < enginePriority.count
    }

    /// Called by an engine when it can't start the stream. Advances to the next
    /// engine in the priority list if one is available; the engine view rebuilds
    /// against the new engine. When the list is exhausted this is never called
    /// (the last engine shows its own error overlay instead), so there's nothing
    /// to do here in that case.
    private func fallBackToNextEngine() {
        guard hasFallbackEngine else { return }
        let failed = engine
        engineAttempt += 1
        PlaybackQoE.shared.noteEngineFallback(to: engine)
        Logger.player.log("engine \(failed.rawValue, privacy: .public) could not start the stream; falling back to \(engine.rawValue, privacy: .public)")
    }

    /// An engine reported it can't start the stream. During an AirPlay override
    /// this means AVPlayer can't cast this particular stream's video, so drop the
    /// override and let the user's engine play it locally (audio keeps routing to
    /// the receiver) rather than surfacing a misleading "offline" error. Outside a
    /// cast it's the normal engine-fallback path.
    private func handlePlaybackFailure() {
        guard isAirPlayOverride else {
            fallBackToNextEngine()
            return
        }
        Logger.player.log("AirPlay: AVPlayer can't play this stream; reverting to \(priorityEngine.rawValue, privacy: .public) locally with audio-only AirPlay")
        airPlayVideoUnsupported.insert(activeMedia.id)
        // Resume the local engine where the cast attempt left off (VOD only).
        if !activeMedia.isLive, clock.current > 1 {
            resumeActiveMedia(at: clock.current)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            // The engines pin their video surfaces edge-to-edge themselves, so
            // only strip the safe area from the whole engine view (controls
            // included) on platforms without system chrome. On iOS the
            // controls must respect it: the status bar re-appears over the
            // player whenever a system sheet is up (e.g. the AirPlay picker),
            // and a top bar laid out in the status-bar / Dynamic-Island region
            // collides with the clock and cellular indicators.
            #if os(iOS)
                playerView
            #else
                playerView
                    .ignoresSafeArea()
            #endif

            // VLCKit and KSPlayer ship their own close button inside the
            // auto-hiding controls overlay — showing a second one here means
            // the user sees duplicate X buttons whenever the controls are
            // visible. Only render our custom close for engines that don't
            // draw their own controls.
            if !engine.rendersOwnControls {
                closeButton
                    .padding(.top, 4)
                    .padding(.leading, 4)
            }
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .macPlayerWindow(activeMedia: activeMedia, launchMedia: media) { switchMedia(to: $0) }
        // Synchronous on purpose, and ahead of the `.task` below: the engine
        // coordinators report `beginStartup` / `noteEngineFallback` from their
        // own appearance, and an async baseline can land after them — which
        // would bake a fault the viewer just lived through into the "before"
        // snapshot and read the session as flawless.
        .onAppear { beginReviewSession() }
        .task {
            // Seed the recall pair with the channel we opened on, so the very
            // first in-player recall has somewhere to jump back to.
            LiveChannelHistory.record(activeMedia)
            // Pause background indexing — its periodic saves merge into the
            // main context and hitch KSPlayer's render loop.
            ContentIndexingService.shared.isPlaybackActive = true
            configureAudioSessionForPlayback()
        }
        .task(id: activeMedia.id) {
            // Resolve a deferred Stalker placeholder into a real (short-lived)
            // stream URL before the engine loads it. No-op for Xtream / m3u.
            await resolveActiveMedia()
        }
        .task(id: activeMedia.id) {
            // Publish the session system-wide: Now Playing metadata + remote
            // commands (lock screen, Control Center, the iPhone's Apple TV
            // remote) and the iOS Live Activity. Runs per active stream so a
            // channel surf / next episode republishes; cancelled on swap.
            await NowPlayingService.shared.runSession(
                media: activeMedia, clock: clock, container: modelContext.container
            )
        }
        .task(id: activeMedia.id) {
            // Resolve the transport neighbours (previous/next episode or channel)
            // and the IntroDB segments for the active stream. Runs on appear and
            // whenever the stream swaps, so what the controls play always trails
            // what is on screen. The segments feed two affordances — the
            // skip-intro button (intro/recap windows) and the next-up arm time
            // (outro window) — so the fetch needs one of them to be both enabled
            // and reachable; the outro is dead weight with no next episode to
            // advance to. Resolving the lookup key touches SwiftData on the main
            // actor; the fetch itself is off it.
            itemNeighbours = Self.resolveNeighbours(
                for: activeMedia, sortRaw: liveContentSortRaw, restriction: contentRestriction, in: modelContext
            )
            nextUpMedia = Self.queuedEpisode(from: itemNeighbours)
            skipSegments = nil
            guard PremiumManager.shared.isPremium,
                  PlayerSettings.Playback.showSkipIntroButton
                  || (PlayerSettings.Playback.showNextEpisodeButton && nextUpMedia != nil),
                  !activeMedia.isLive,
                  let lookup = IntroSkipResolver.lookup(for: activeMedia.contentRef, in: modelContext)
            else { return }
            skipSegments = try? await IntroDBClient.shared.segments(
                imdbId: lookup.imdbId, season: lookup.season, episode: lookup.episode
            )
        }
        .task {
            // Sample progress on a cadence and stash it in `WatchProgressBuffer`
            // (UserDefaults) rather than writing SwiftData. A background-context
            // save still forces the main context to merge and re-run every
            // `@Query` on `Movie`/`Episode`/`Series` (e.g. Home's continue-
            // watching rows) on the main thread — that merge is what hitched
            // KSPlayer every few seconds. Buffering triggers neither, so the only
            // periodic main-thread work is reading two clock values. The buffer
            // is flushed to SwiftData at safe boundaries (see `persistProgressDetached`).
            progressWriter = WatchProgressWriter(container: modelContext.container)
            // while !Task.isCancelled {
            //     try? await Task.sleep(for: .seconds(Self.progressSampleInterval))
            //     guard !Task.isCancelled else { break }
            //     bufferProgress()
            // }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground is a safe moment to flush; covers the user
            // backgrounding the app mid-playback without closing the player.
            if phase != .active { persistProgressDetached(force: true) }
            #if os(tvOS)
                // tvOS has no background playback for any engine, so a stream
                // left running behind the Home screen just keeps buffering and
                // holding the decoder. When the app actually leaves the
                // foreground, close the player so every engine tears its stream
                // down via `onDisappear`. `.inactive` is a transient transition
                // (a system overlay, the screensaver arming) where the app is
                // still foreground, so only act on a real `.background` move.
                if phase == .background { closePlayer() }
            #endif
        }
        .onChange(of: castService.isAirPlayActive) { _, isActive in
            // While the audio-only sentinel is set the engine stays on the
            // user's choice for both route directions — reassigning the media
            // would only restart a stream that is already playing locally.
            let engineSwaps = !airPlayVideoUnsupported.contains(activeMedia.id)
            if !isActive {
                // The route is gone; a future cast (possibly to a different,
                // more capable receiver) should retry AVPlayer video first.
                airPlayVideoUnsupported.removeAll()
            }
            // Toggling AirPlay swaps the engine (see `engine`), which rebuilds the
            // player. Carry the current position across so a VOD stream resumes
            // where it was rather than jumping back to the saved resume point.
            // Live streams have no position, and if the user is already on
            // AVPlayer there's no swap to bridge.
            guard engineSwaps, priorityEngine != .avPlayer, !activeMedia.isLive, clock.current > 1 else { return }
            resumeActiveMedia(at: clock.current)
        }
        .onDisappear {
            // Capture the clock synchronously, then flush off the main thread.
            persistProgressDetached(force: true)
            NowPlayingService.shared.endSession()
            releaseAudioSession()
            ContentIndexingService.shared.isPlaybackActive = false
            endReviewSession(isChildWatching: profileManager?.activeProfileIsChild ?? false)
        }
    }

    /// The media to hand the engine. For a directly playable stream (Xtream /
    /// m3u) this is `activeMedia` itself, so playback starts with no extra step.
    /// For a Stalker placeholder it is the resolved copy, gated on its identity
    /// matching the active stream so a stale resolution from the previous stream
    /// never reaches the engine during a channel/episode switch.
    private var displayMedia: PlayableMedia? {
        guard StalkerLink.isPlaceholder(activeMedia.url) else { return activeMedia }
        guard let resolvedMedia, resolvedMedia.id == activeMedia.id else { return nil }
        return resolvedMedia
    }

    @ViewBuilder
    private var playerView: some View {
        if let media = displayMedia {
            engineView(for: media)
        } else if resolveError != nil {
            // Stalker `create_link` failed — surface the failure with a retry
            // rather than spinning forever.
            PlayerErrorIndicator(title: activeMedia.title, onRetry: retryResolve, onClose: closePlayer)
        } else {
            // Resolving the Stalker stream URL before the engine can load it.
            PlayerLoadingIndicator(title: activeMedia.title)
        }
    }

    @ViewBuilder
    private func engineView(for media: PlayableMedia) -> some View {
        // Keyed on the engine attempt so falling back tears the failed engine
        // down and builds the next one fresh, rather than reusing in-flight state.
        switch engine {
        case .lumeEngine:
            LumeEngineEngineView(
                media: media, clock: clock, mediaSwapper: mediaSwapper,
                nextUpMedia: nextUpMedia, itemNeighbours: itemNeighbours,
                skipSegments: skipSegments,
                reportsStartupFailure: hasFallbackEngine,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackFailed: fallBackToNextEngine,
                onSelectMedia: switchMedia,
                onCompleteCurrentItem: completeActiveEpisode, onRemoteAdvance: remoteAdvanceHandler
            )
            .id(engineAttempt)
        case .avPlayer:
            AVPlayerEngineView(
                media: media, clock: clock, mediaSwapper: mediaSwapper,
                nextUpMedia: nextUpMedia, itemNeighbours: itemNeighbours,
                skipSegments: skipSegments,
                // During an AirPlay override there's no next engine to try, but
                // report failure anyway so `handlePlaybackFailure` can revert to
                // local playback instead of AVPlayer raising its offline overlay.
                // The cast attempt keeps the full startup window: giving up
                // early would drop slow-to-start streams to audio-only when a
                // few more seconds would have cast them fine.
                reportsStartupFailure: isAirPlayOverride || hasFallbackEngine,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackFailed: handlePlaybackFailure,
                onSelectMedia: switchMedia,
                onCompleteCurrentItem: completeActiveEpisode, onRemoteAdvance: remoteAdvanceHandler
            )
            .id(engineAttempt)
        case .ksPlayer:
            KSPlayerEngineView(
                media: media, clock: clock, mediaSwapper: mediaSwapper,
                nextUpMedia: nextUpMedia, itemNeighbours: itemNeighbours,
                skipSegments: skipSegments,
                reportsStartupFailure: hasFallbackEngine,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackFailed: fallBackToNextEngine,
                onSelectMedia: switchMedia,
                onCompleteCurrentItem: completeActiveEpisode, onRemoteAdvance: remoteAdvanceHandler
            )
            .id(engineAttempt)
        case .vlcKit:
            VLCPlayerEngineView(
                media: media, clock: clock, mediaSwapper: mediaSwapper,
                nextUpMedia: nextUpMedia, itemNeighbours: itemNeighbours,
                skipSegments: skipSegments,
                reportsStartupFailure: hasFallbackEngine,
                usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackFailed: fallBackToNextEngine,
                onSelectMedia: switchMedia,
                onCompleteCurrentItem: completeActiveEpisode, onRemoteAdvance: remoteAdvanceHandler
            )
            .id(engineAttempt)
        }
    }

    /// Resolves the active Stalker placeholder into a playable URL. A no-op for
    /// directly playable streams. Re-runs whenever the active stream changes
    /// (open, channel surf, next episode), so each switch resolves a fresh,
    /// short-lived URL.
    private func resolveActiveMedia() async {
        guard StalkerLink.isPlaceholder(activeMedia.url) else { return }
        resolvedMedia = nil
        resolveError = nil
        do {
            resolvedMedia = try await StalkerStreamResolver.resolve(activeMedia, container: modelContext.container)
        } catch {
            resolveError = error.localizedDescription
            let detail = (error as? StalkerError)?.logDescription ?? LogRedaction.describe(error)
            Logger.player.error("Stalker stream resolution failed: \(detail, privacy: .public)")
        }
    }

    private func retryResolve() {
        engineAttempt = 0
        Task { await resolveActiveMedia() }
    }

    private var closeButton: some View {
        Button {
            persistProgressDetached(force: true)
            closePlayer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Close player")
        #if !os(tvOS)
            .keyboardShortcut(.escape, modifiers: [])
        #endif
    }

    private func closePlayer() {
        #if os(macOS)
            // Exit fullscreen first so the window animation is graceful, then close.
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            dismissWindow(id: "player")
        #else
            dismiss()
        #endif
    }

    /// Seconds between progress samples. These only write `UserDefaults` now, so
    /// the cadence trades crash-recovery granularity against nothing meaningful.
    private static let progressSampleInterval: TimeInterval = 30

    /// Stash the current progress in `WatchProgressBuffer`. The only main-actor
    /// work is reading two `Double`s off the clock; the JSON + `UserDefaults`
    /// write is dispatched onto the buffer's background queue, so it can't stall
    /// KSPlayer's main-run-loop frame presentation. No SwiftData, no store merge,
    /// no `@Query` invalidation. Live streams carry no progress.
    private func bufferProgress() {
        guard !activeMedia.isLive else { return }
        WatchProgressBuffer.record(
            ref: activeMedia.contentRef,
            progress: clock.current,
            duration: clock.duration
        )
    }

    /// Commit the current progress to SwiftData off the main thread. Called only
    /// at boundaries (close, episode switch, app backgrounding) where the one
    /// resulting store merge can't disturb playback. Captures the clock
    /// synchronously *before* awaiting, so a subsequent `clock.reset()` can't
    /// race the read; clears the buffer entry once the write lands.
    func persistProgressDetached(force: Bool) {
        guard let writer = progressWriter else { return }
        if activeMedia.isLive, !force { return }
        let ref = activeMedia.contentRef
        // An explicit "next episode" already settled this stream at its full
        // duration. Recording the position it was skipped from would walk that
        // back to unwatched, so the completion stands and this flush stands down.
        if ref == completedRef { return }
        let now = clock.current
        let total = clock.duration
        // Held so `endReviewSession` can await it: `writer` is an actor, so the
        // await below suspends, and without the handle the review policy would
        // read `completedTitles` before this task increments it — the third
        // finished title would then only arm the *next* session.
        let previous = pendingProgressWrite
        pendingProgressWrite = Task { @MainActor in
            await previous?.value
            let completion = await writer.record(
                ref: ref, progress: now, duration: total, force: force
            )
            WatchProgressBuffer.remove(ref: ref)
            if let completion {
                syncWatchedServices(ref: completion.ref)
                AppStoreReviewPrompt.shared.noteCompletedTitle()
            }
        }
    }

    /// One-time "watched" sync to every connected tracker. Runs at most once per
    /// title (when it crosses 90%), so the main-context fetch here is off the
    /// playback hot path. The services are `@MainActor`, hence this stays on the
    /// main actor.
    func syncWatchedServices(ref: PlayableMedia.ContentRef) {
        switch ref {
        case let .movie(id):
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let movie = try? modelContext.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(movie: movie, watched: true)
            SimklService.shared.syncWatched(movie: movie, watched: true)
        case let .episode(id):
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let episode = try? modelContext.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(episode: episode, watched: true)
            SimklService.shared.syncWatched(episode: episode, watched: true)
        case .live:
            break
        }
    }
}

#Preview {
    FullScreenPlayerView(media: PlayableMedia(
        id: "preview",
        url: URL(string: "https://example.com/stream.m3u8")!,
        title: "Sample Stream",
        subtitle: nil,
        posterURL: nil,
        kind: .live,
        startTime: 0,
        contentRef: .live("preview")
    ))
    .preferredColorScheme(.dark)
}
