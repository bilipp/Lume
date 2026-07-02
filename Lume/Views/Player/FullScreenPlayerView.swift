import AVFoundation
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
    @State private var engineAttempt = 0

    /// Observes the active AirPlay route. Full-screen AirPlay *video* is only
    /// possible through `AVPlayer` (KSPlayer/VLCKit render into their own layers,
    /// so AirPlay would carry only their audio), so while a route is active the
    /// stream is driven through the AVPlayer engine regardless of the user's
    /// engine preference. See `engine` / `castService`.
    @State private var castService = CastService.shared

    /// Id of a stream AVPlayer couldn't start while casting over AirPlay (a codec
    /// or container AVPlayer can't open — common for MPEG-TS / MKV IPTV that only
    /// KSPlayer/VLCKit handle). Once set, the AirPlay-forces-AVPlayer override is
    /// dropped for that stream so it plays on the user's engine locally with the
    /// audio still on the receiver, instead of a dead "stream offline" error.
    @State private var airPlayVideoUnsupported: String?

    /// The only high-frequency playback state. An `@Observable` the host owns
    /// but never reads in its own body, so playback ticks invalidate just the
    /// scrubber/time labels rather than re-rendering the whole player tree. See
    /// `PlaybackClock`.
    @State private var clock = PlaybackClock()

    /// Writes watch progress on a private background `ModelContext`. Saving on
    /// the main context mid-playback hitches KSPlayer's render loop, so the
    /// sampler below only reads the clock and hands `Sendable` values to this
    /// actor. Created in `.task` once the environment's container is available.
    @State private var progressWriter: WatchProgressWriter?

    /// The stream currently playing. Starts as `media` but can be swapped when
    /// the viewer picks another episode from the in-player episode rail (tvOS).
    @State private var activeMedia: PlayableMedia

    /// The Stalker-resolved stand-in for `activeMedia`. Stalker streams arrive as
    /// a `lumestalker://` placeholder whose real URL is fetched via `create_link`
    /// at playback time; this holds the resolved copy once it lands. `nil` while
    /// resolution is in flight (the loading indicator shows). Engines that play a
    /// directly usable URL (Xtream / m3u) bypass this entirely — see `displayMedia`.
    @State private var resolvedMedia: PlayableMedia?

    /// Set when Stalker `create_link` resolution fails, so the host shows the
    /// failure overlay instead of an endless spinner.
    @State private var resolveError: String?

    /// The episode queued to play after `activeMedia`, resolved whenever the
    /// active stream changes. Drives both the in-player Next Episode button and
    /// auto-advance (see `PlayerNextUpOverlay`); `nil` for movies, live channels
    /// and series finales. Read only when the player tree is (re)built, never on
    /// the per-tick clock path.
    @State private var nextUpMedia: PlayableMedia?

    /// Intro / recap timestamps for the active episode (from IntroDB), driving
    /// the in-player Skip Intro button. `nil` for movies, live channels, and
    /// episodes IntroDB doesn't know — resolved whenever the active stream
    /// changes. Read only when the player tree is (re)built, never on the
    /// per-tick clock path. See `PlayerSkipIntroOverlay`.
    @State private var skipSegments: IntroSegments?

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
            && airPlayVideoUnsupported != activeMedia.id
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
        airPlayVideoUnsupported = activeMedia.id
        // Resume the local engine where the cast attempt left off (VOD only).
        if !activeMedia.isLive, clock.current > 1 {
            activeMedia = activeMedia.resuming(at: clock.current)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            playerView
                .ignoresSafeArea()

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
        .task {
            // Seed the recall pair with the channel we opened on, so the very
            // first in-player recall has somewhere to jump back to.
            LiveChannelHistory.record(activeMedia)
            // Pause background indexing — its periodic saves merge into the
            // main context and hitch KSPlayer's render loop.
            ContentIndexingService.shared.isPlaybackActive = true
            configureAudioSessionForPlayback()
            #if os(macOS)
                enterMacFullScreen()
            #endif
        }
        .task(id: activeMedia.id) {
            // Resolve a deferred Stalker placeholder into a real (short-lived)
            // stream URL before the engine loads it. No-op for Xtream / m3u.
            await resolveActiveMedia()
        }
        .task(id: activeMedia.id) {
            // Resolve the next episode for the active stream. Runs on appear and
            // whenever the stream swaps (manual pick or auto-advance), so the
            // queued episode always trails the one on screen.
            nextUpMedia = activeMedia.isLive
                ? nil
                : NextEpisodeResolver.nextMedia(after: activeMedia.contentRef, in: modelContext)
        }
        .task(id: activeMedia.id) {
            // Resolve the IntroDB skip windows for the active episode. Runs on
            // appear and whenever the stream swaps. Gated on the user setting so
            // a disabled feature makes no network call. Resolving the lookup key
            // touches SwiftData on the main actor; the fetch itself is off it.
            skipSegments = nil
            guard PremiumManager.shared.isPremium, PlayerSettings.Playback.showSkipIntroButton, !activeMedia.isLive,
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
        .onChange(of: castService.isAirPlayActive) { _, _ in
            // Toggling AirPlay swaps the engine (see `engine`), which rebuilds the
            // player. Carry the current position across so a VOD stream resumes
            // where it was rather than jumping back to the saved resume point.
            // Live streams have no position, and if the user is already on
            // AVPlayer there's no swap to bridge.
            guard priorityEngine != .avPlayer, !activeMedia.isLive, clock.current > 1 else { return }
            activeMedia = activeMedia.resuming(at: clock.current)
        }
        .onDisappear {
            // Capture the clock synchronously, then flush off the main thread.
            persistProgressDetached(force: true)
            releaseAudioSession()
            ContentIndexingService.shared.isPlaybackActive = false
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
        case .avPlayer:
            AVPlayerEngineView(
                media: media,
                clock: clock,
                nextUpMedia: nextUpMedia,
                skipSegments: skipSegments,
                // During an AirPlay override there's no next engine to try, but
                // report failure anyway so `handlePlaybackFailure` can revert to
                // local playback instead of AVPlayer raising its offline overlay.
                fallbackAvailable: isAirPlayOverride ? true : hasFallbackEngine,
                onPlaybackFailed: handlePlaybackFailure,
                onSelectMedia: switchMedia
            )
            .id(engineAttempt)
        case .ksPlayer:
            KSPlayerEngineView(
                media: media,
                clock: clock,
                nextUpMedia: nextUpMedia,
                skipSegments: skipSegments,
                fallbackAvailable: hasFallbackEngine,
                onPlaybackFailed: fallBackToNextEngine,
                onSelectMedia: switchMedia
            )
            .id(engineAttempt)
        case .vlcKit:
            VLCPlayerEngineView(
                media: media,
                clock: clock,
                nextUpMedia: nextUpMedia,
                skipSegments: skipSegments,
                fallbackAvailable: hasFallbackEngine,
                onPlaybackFailed: fallBackToNextEngine,
                onSelectMedia: switchMedia
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
            Logger.player.error("Stalker stream resolution failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func retryResolve() {
        engineAttempt = 0
        Task { await resolveActiveMedia() }
    }

    /// Persist the outgoing stream's progress, then swap in a new one. The
    /// engine reconfigures its player when `activeMedia` changes.
    private func switchMedia(to newMedia: PlayableMedia) {
        guard newMedia.id != activeMedia.id else { return }
        // Flush the outgoing stream's progress before the clock resets — capture
        // happens synchronously inside `persistProgressDetached`.
        persistProgressDetached(force: true)
        clock.reset()
        // Restart the fallback chain from the primary engine for the new stream.
        engineAttempt = 0
        activeMedia = newMedia
        // Slide the outgoing channel into the recall slot so `right` can jump back.
        LiveChannelHistory.record(newMedia)
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

    private func configureAudioSessionForPlayback() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true, options: [])
        #endif
    }

    private func releaseAudioSession() {
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(macOS)
        private func enterMacFullScreen() {
            // Wait for the window to mount before toggling fullscreen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let window = NSApp.keyWindow ?? NSApp.windows.last(where: { $0.isVisible }) else { return }
                window.title = activeMedia.title
                if !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
    #endif

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
    private func persistProgressDetached(force: Bool) {
        guard let writer = progressWriter else { return }
        if activeMedia.isLive, !force { return }
        let ref = activeMedia.contentRef
        let now = clock.current
        let total = clock.duration
        Task { @MainActor in
            let completion = await writer.record(
                ref: ref, progress: now, duration: total, force: force
            )
            WatchProgressBuffer.remove(ref: ref)
            if let completion { syncTraktWatched(ref: completion.ref) }
        }
    }

    /// One-time "watched" sync on Trakt. Runs at most once per title (when it
    /// crosses 90%), so the main-context fetch here is off the playback hot path.
    /// `TraktService` is `@MainActor`, hence this stays on the main actor.
    private func syncTraktWatched(ref: PlayableMedia.ContentRef) {
        switch ref {
        case let .movie(id):
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let movie = try? modelContext.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(movie: movie, watched: true)
        case let .episode(id):
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let episode = try? modelContext.fetch(descriptor).first else { return }
            TraktService.shared.syncWatched(episode: episode, watched: true)
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
