//
//  NowPlayingService.swift
//  Lume
//
//  Publishes the active playback session to the system: `MPNowPlayingInfoCenter`
//  metadata + `MPRemoteCommandCenter` transport on every platform, and (on iOS)
//  the lock-screen / Dynamic Island Live Activity. On tvOS this is what makes
//  an iPhone's Apple TV remote surface show what Lume is playing.
//
//  One instance serves all four engines. `FullScreenPlayerView` runs a session
//  per active stream; the engine views attach a `Transport` while they are on
//  screen so remote commands can drive whichever engine is playing.
//

import Foundation
import MediaPlayer
import OSLog
import SwiftData
#if os(macOS)
    // `PlatformImage` is `NSImage` here, and `MediaPlayer` does not pull AppKit
    // in the way it pulls UIKit on iOS.
    import AppKit
#endif

final class NowPlayingService {
    static let shared = NowPlayingService()

    /// The engine-agnostic transport surface remote commands drive.
    struct Transport {
        let isPlaying: () -> Bool
        let play: () -> Void
        let pause: () -> Void
        let seek: (TimeInterval) -> Void
        /// Play the stream on `step`'s side — the episode either side of this
        /// one, or the channel one position along the live list — reporting
        /// whether anything actually started. Supplied by the player host, which
        /// owns both the swap and the resolved neighbours; the engine only
        /// carries it here. `nil` where the host offers no in-player navigation.
        var advance: ((PlayerMediaSwapper.Step) -> Bool)?
    }

    /// The stream whose session is currently published, if any. Read by the
    /// `lume://resume` deep-link handler to avoid re-presenting a player that
    /// is already up.
    private(set) var currentMedia: PlayableMedia?

    private var transport: Transport?
    /// Identity of the engine coordinator that attached the current transport.
    /// Engine swaps overlap (the new engine's `onAppear` can precede the old
    /// one's `onDisappear`), so a detach only clears its own attach.
    private var transportOwner: ObjectIdentifier?

    private var clock: PlaybackClock?
    private var artwork: MPMediaItemArtwork?
    private var channelName: String?
    private var channelEPG: ChannelEPG?

    private init() {}

    // MARK: - Session lifecycle

    /// Attach the transport of the engine currently on screen. `owner` is the
    /// engine's coordinator, so a stale detach from a torn-down engine can't
    /// drop a newer engine's transport.
    func attachTransport(_ transport: Transport, owner: AnyObject) {
        self.transport = transport
        transportOwner = ObjectIdentifier(owner)
        // An engine swap mid-session tears the old engine down, and KSPlayer's
        // layer deinit strips every target from the shared command center —
        // ours included. Re-registering on each attach keeps commands alive
        // across engine fallbacks.
        if let media = currentMedia {
            registerCommands(for: media)
        }
    }

    func detachTransport(owner: AnyObject) {
        guard transportOwner == ObjectIdentifier(owner) else { return }
        transport = nil
        transportOwner = nil
    }

    /// Publishes `media` for as long as the calling `.task(id:)` lives — the
    /// host cancels and restarts it on every stream swap (channel surf, next
    /// episode). Registers remote commands, publishes metadata + artwork,
    /// keeps live-TV EPG now/next fresh across programme boundaries, and
    /// drives the iOS Live Activity.
    func runSession(media: PlayableMedia, clock: PlaybackClock, container: ModelContainer) async {
        currentMedia = media
        self.clock = clock
        channelName = nil
        channelEPG = nil
        artwork = nil
        PlaybackResumeStore.save(media)
        registerCommands(for: media)
        publish()
        #if os(iOS)
            PlaybackActivityController.shared.startOrUpdate(state: makeActivityState())
        #endif

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadArtwork(for: media) }
            if media.isLive {
                group.addTask { await self.refreshEPGLoop(media: media, container: container) }
            }
            group.addTask { await self.samplerLoop() }
        }
    }

    /// Tear the whole session down: player dismissed. Also snapshots the final
    /// position so the Live Activity's tap-to-resume can reopen where playback
    /// left off even after the session is gone.
    func endSession() {
        if let media = currentMedia {
            let position = clock?.current ?? 0
            PlaybackResumeStore.save(
                !media.isLive && position > 1 ? media.resuming(at: position) : media
            )
        }
        currentMedia = nil
        clock = nil
        artwork = nil
        channelEPG = nil
        channelName = nil
        removeCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
            PlaybackActivityController.shared.end()
        #endif
    }

    // MARK: - Remote commands

    private var commandTargets: [(MPRemoteCommand, Any)] = []

    /// Whether the lock screen should offer next/previous track at all.
    ///
    /// Both halves are required. A stream with no axis (a movie) must not show
    /// the buttons, and neither must a host that supplies no advance handler:
    /// tvOS deliberately hands over a `nil` one — it drives stream changes from
    /// the Siri Remote's own mapping — so enabling on the axis alone advertises
    /// two buttons whose every press can only answer
    /// `.noActionableNowPlayingItem`.
    ///
    /// Split out as a pure function because the service is a `@MainActor`
    /// singleton with no injection seam, and this rule is the part worth
    /// testing.
    nonisolated static func advanceCommandsEnabled(
        for media: PlayableMedia,
        hasAdvanceHandler: Bool
    ) -> Bool {
        hasAdvanceHandler && PlayerItemNavigation.axis(for: media) != nil
    }

    private func registerCommands(for media: PlayableMedia) {
        removeCommands()
        let center = MPRemoteCommandCenter.shared()

        addTarget(center.playCommand) { [weak self] _ in self?.remotePlay() ?? .commandFailed }
        addTarget(center.pauseCommand) { [weak self] _ in self?.remotePause() ?? .commandFailed }
        addTarget(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self, let transport else { return .noActionableNowPlayingItem }
            return transport.isPlaying() ? remotePause() : remotePlay()
        }

        // Next/previous track: the neighbouring episode, or — on live TV —
        // channel up/down. Configured before the seek commands' early return,
        // which live streams take. A press that finds nothing reports
        // `.noSuchContent`.
        let canAdvance = Self.advanceCommandsEnabled(
            for: media,
            hasAdvanceHandler: transport?.advance != nil
        )
        center.nextTrackCommand.isEnabled = canAdvance
        center.previousTrackCommand.isEnabled = canAdvance
        if canAdvance {
            addTarget(center.nextTrackCommand) { [weak self] _ in self?.remoteAdvance(.next) ?? .commandFailed }
            addTarget(center.previousTrackCommand) { [weak self] _ in self?.remoteAdvance(.previous) ?? .commandFailed }
        }

        let canSeek = !media.isLive
        center.changePlaybackPositionCommand.isEnabled = canSeek
        center.skipForwardCommand.isEnabled = canSeek
        center.skipBackwardCommand.isEnabled = canSeek
        guard canSeek else { return }

        addTarget(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return remoteSeek(to: event.positionTime)
        }
        center.skipForwardCommand.preferredIntervals = [15]
        addTarget(center.skipForwardCommand) { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            return remoteSeek(to: (clock?.current ?? 0) + event.interval)
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        addTarget(center.skipBackwardCommand) { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            return remoteSeek(to: max(0, (clock?.current ?? 0) - event.interval))
        }
    }

    private func addTarget(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        commandTargets.append((command, command.addTarget(handler: handler)))
    }

    private func removeCommands() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
    }

    private func remotePlay() -> MPRemoteCommandHandlerStatus {
        guard let transport else { return .noActionableNowPlayingItem }
        if !transport.isPlaying() { transport.play() }
        publishDynamic(forcePlaying: true)
        return .success
    }

    private func remotePause() -> MPRemoteCommandHandlerStatus {
        guard let transport else { return .noActionableNowPlayingItem }
        if transport.isPlaying() { transport.pause() }
        publishDynamic(forcePlaying: false)
        return .success
    }

    private func remoteAdvance(_ step: PlayerMediaSwapper.Step) -> MPRemoteCommandHandlerStatus {
        guard let advance = transport?.advance else { return .noActionableNowPlayingItem }
        return advance(step) ? .success : .noSuchContent
    }

    private func remoteSeek(to position: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let transport else { return .noActionableNowPlayingItem }
        transport.seek(position)
        clock?.current = position
        publishDynamic()
        return .success
    }

    // MARK: - Publishing

    /// Full metadata publish — on session start, EPG programme change, or after
    /// an engine cleared the info center behind our back.
    private func publish() {
        guard let media = currentMedia else { return }
        var info: [String: Any] = [:]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = media.isLive
        if media.isLive, let programme = channelEPG?.current {
            info[MPMediaItemPropertyTitle] = programme.title
            info[MPMediaItemPropertyArtist] = channelName ?? media.title
        } else {
            info[MPMediaItemPropertyTitle] = media.title
            if let subtitle = media.subtitle {
                info[MPMediaItemPropertyArtist] = subtitle
            }
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let playing = transport?.isPlaying() ?? true
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        if let clock, !media.isLive {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.current
            if clock.duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = clock.duration
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        setPlaybackState(playing: playing)
    }

    /// Cheap update of the values that move — elapsed / duration / rate —
    /// preserving the metadata keys already published.
    private func publishDynamic(forcePlaying: Bool? = nil) {
        guard let media = currentMedia else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        // An engine teardown (KSPlayer's stop clears the info center) leaves an
        // empty dict — fall back to a full publish so the metadata comes back.
        guard info[MPMediaItemPropertyTitle] != nil else {
            publish()
            return
        }
        let playing = forcePlaying ?? transport?.isPlaying() ?? true
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        if let clock, !media.isLive {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.current
            if clock.duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = clock.duration
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        setPlaybackState(playing: playing)
        #if os(iOS)
            PlaybackActivityController.shared.startOrUpdate(state: makeActivityState(isPaused: !playing))
        #endif
    }

    /// `playbackState` drives the macOS Now Playing widget; iOS/tvOS infer the
    /// state from `playbackRate` and ignore it.
    private func setPlaybackState(playing: Bool) {
        #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #endif
    }

    // MARK: - Artwork

    private func loadArtwork(for media: PlayableMedia) async {
        guard let posterURL = media.posterURL else { return }
        guard let image = try? await ImagePipeline.shared.image(for: posterURL, maxPixelSize: 600) else { return }
        guard currentMedia?.id == media.id else { return }
        artwork = Self.makeArtwork(image)
        publish()
        #if os(iOS)
            PlaybackActivityController.shared.setArtwork(image, mediaID: media.id)
            PlaybackActivityController.shared.startOrUpdate(state: makeActivityState())
        #endif
    }

    /// The request handler is invoked by the system from arbitrary threads;
    /// capturing the immutable image by value keeps it isolation-safe.
    private nonisolated static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { [image] _ in image }
    }

    // MARK: - Live TV EPG

    /// Keeps the published programme fresh: resolves now/next for the channel,
    /// then sleeps until the programme boundary and resolves again.
    private func refreshEPGLoop(media: PlayableMedia, container: ModelContainer) async {
        guard case let .live(streamID) = media.contentRef else { return }
        while !Task.isCancelled {
            let resolved = await Task.detached {
                Self.resolveChannelEPG(streamID: streamID, container: container)
            }.value
            guard !Task.isCancelled, currentMedia?.id == media.id else { return }
            channelName = resolved?.channelName
            channelEPG = resolved?.epg
            publish()
            #if os(iOS)
                PlaybackActivityController.shared.startOrUpdate(state: makeActivityState())
            #endif
            // Re-resolve at the programme boundary; when the guide has no
            // current entry, retry on a slow cadence in case a sync lands one.
            let boundary = resolved?.epg.current?.end ?? Date.now.addingTimeInterval(15 * 60)
            let delay = max(30, boundary.timeIntervalSinceNow + 2)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private nonisolated static func resolveChannelEPG(
        streamID: String, container: ModelContainer
    ) -> (channelName: String, epg: ChannelEPG)? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamID })
        descriptor.fetchLimit = 1
        guard let stream = try? context.fetch(descriptor).first else { return nil }
        guard let channelId = stream.epgChannelId, !channelId.isEmpty else {
            return (stream.name, ChannelEPG(current: nil, next: nil))
        }
        let epg = ChannelEPGLoader.load(container: container, channelIds: [channelId], now: .now)
        return (stream.name, epg[channelId] ?? ChannelEPG(current: nil, next: nil))
    }

    // MARK: - State sampler

    /// A cheap once-a-second look at the clock and transport. Catches the state
    /// changes that don't flow through the remote commands — in-app play/pause,
    /// scrubber seeks, engine restarts, and KSPlayer wiping the info center on
    /// an engine rebuild — without touching SwiftData or the render loop.
    private func samplerLoop() async {
        var lastElapsed = clock?.current ?? 0
        var lastDuration = clock?.duration ?? 0
        var lastPlaying = transport?.isPlaying() ?? true
        var lastWall = Date.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let clock else { return }
            let playing = transport?.isPlaying() ?? lastPlaying
            let wallDelta = Date.now.timeIntervalSince(lastWall)
            let expected = lastElapsed + (lastPlaying ? wallDelta : 0)
            let drifted = abs(clock.current - expected) > 3
            let durationChanged = clock.duration != lastDuration
            let cleared = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] == nil
            if cleared, let media = currentMedia {
                // An engine teardown wiped the info center (and, for KSPlayer,
                // the command targets with it) — take the session back.
                registerCommands(for: media)
            }
            if playing != lastPlaying || drifted || durationChanged || cleared {
                publishDynamic()
            }
            lastElapsed = clock.current
            lastDuration = clock.duration
            lastPlaying = playing
            lastWall = .now
        }
    }

    // MARK: - Live Activity state

    #if os(iOS)
        private func makeActivityState(isPaused: Bool? = nil) -> PlaybackActivityAttributes.ContentState {
            let media = currentMedia
            let paused = isPaused ?? !(transport?.isPlaying() ?? true)
            var state = PlaybackActivityAttributes.ContentState(
                title: media?.title ?? "",
                subtitle: media?.subtitle,
                isLive: media?.isLive ?? false,
                isPaused: paused
            )
            if media?.isLive == true {
                state.programmeTitle = channelEPG?.current?.title
                state.windowStart = channelEPG?.current?.start
                state.windowEnd = channelEPG?.current?.end
                state.nextTitle = channelEPG?.next?.title
                state.nextStart = channelEPG?.next?.start
            } else if let clock, clock.duration > 0 {
                state.elapsed = clock.current
                state.duration = clock.duration
                state.windowStart = Date.now.addingTimeInterval(-clock.current)
                state.windowEnd = Date.now.addingTimeInterval(clock.duration - clock.current)
            }
            return state
        }
    #endif
}

/// Snapshot of the last played stream, for the Live Activity's tap-to-resume
/// (`lume://resume`) after the player — or the whole app — is gone.
/// `PlayableMedia` is `Codable`, so the snapshot round-trips as JSON.
enum PlaybackResumeStore {
    private static let key = "nowPlaying.lastMediaSnapshot"

    static func save(_ media: PlayableMedia) {
        guard let data = try? JSONEncoder().encode(media) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PlayableMedia? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlayableMedia.self, from: data)
    }
}
