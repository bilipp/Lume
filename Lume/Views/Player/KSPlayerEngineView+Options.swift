//
//  KSPlayerEngineView+Options.swift
//  Lume
//
//  Builds the `KSOptions` for a playback session from the user's saved KSPlayer
//  settings (see `KSPlayerOptions`). Split out of `KSPlayerEngineView` to keep
//  that view file focused on the SwiftUI body.
//

import CoreMedia
import Foundation
import KSPlayer
import os
import SwiftUI

/// `KSOptions` that resolves the viewer's preferred audio language while the
/// stream is being opened.
///
/// `wantedAudio(tracks:)` is the only sanctioned pre-selection hook: KSPlayer
/// consults it inside `MEPlayerItem`'s open, before any decoder exists, so no
/// track ever starts and gets swapped. `player.select(track:)` stays reserved
/// for manual picks, and re-preparing a running layer to apply a language is a
/// documented use-after-free.
///
/// Only audio. KSPlayer declares no wanted-subtitle counterpart and reports no
/// forced disposition, so subtitle pre-selection and forced-subtitle handling
/// are not available on this engine. The hook also lives on the FFmpeg engine
/// alone — `KSAVPlayer` never reads it.
final nonisolated class LumeKSOptions: KSOptions {
    private let preferredAudioLanguages: [String]

    /// A manual pick wins for the rest of the stream. `rebuildStream(on:)` and
    /// `reconnect()` re-open with this very options instance, which would
    /// otherwise re-assert the preference over the viewer's choice on every
    /// live zap, stall recovery and reconnect. Scoped to one stream: the
    /// coordinator builds a fresh options object whenever the URL changes, so
    /// the flag cannot leak into the next channel or episode.
    ///
    /// Written from the main actor, read on KSPlayer's open thread.
    private let hasManualAudioSelection = OSAllocatedUnfairLock(initialState: false)

    /// Whether this session may switch the TV's display mode when the tvOS
    /// "Match Content" settings are on. KSPlayer sets the frame rate and dynamic
    /// range once the first frame decodes, and clears them when the layer
    /// deinits, so on an embedded tile every zap clears the mode and sets it
    /// again: two HDMI re-syncs, a black screen each time. Only full screen
    /// matches the display, the way AVKit only does it for full-screen playback.
    ///
    /// Written from the main actor, read wherever the layer deinits.
    private let matchesDisplayCriteria: OSAllocatedUnfairLock<Bool>
    /// The last format KSPlayer asked the display to match, applied when full
    /// screen adopts an embedded session that has been holding it back.
    @MainActor private var pendingDisplayCriteria: (refreshRate: Float, isDovi: Bool, format: CMFormatDescription?)?

    init(preferredAudioLanguages: [String], matchesDisplayCriteria: Bool) {
        self.preferredAudioLanguages = preferredAudioLanguages
        self.matchesDisplayCriteria = OSAllocatedUnfairLock(initialState: matchesDisplayCriteria)
        super.init()
    }

    /// Full screen took over this session from the Guide preview: from now on
    /// it matches the display, starting with the stream already playing.
    @MainActor
    func beginMatchingDisplayCriteria() {
        let wasMatching = matchesDisplayCriteria.withLock { matches in
            defer { matches = true }
            return matches
        }
        guard !wasMatching, let pending = pendingDisplayCriteria else { return }
        updateVideo(refreshRate: pending.refreshRate, isDovi: pending.isDovi, formatDescription: pending.format)
    }

    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        pendingDisplayCriteria = (refreshRate, isDovi, formatDescription)
        guard matchesDisplayCriteria.withLock({ $0 }) else { return }
        super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
    }

    /// An embedded session never set the display mode, so it must not reset
    /// it either — that would knock full screen, or the next tile, back to the
    /// interface's mode.
    override func playerLayerDeinit() {
        guard matchesDisplayCriteria.withLock({ $0 }) else { return }
        super.playerLayerDeinit()
    }

    /// Call from every manual audio-track pick, before `select(track:)`.
    func noteManualAudioSelection() {
        hasManualAudioSelection.withLock { $0 = true }
    }

    /// `nil` leaves KSPlayer's own choice (`av_find_best_stream`) untouched —
    /// never index 0, which would change playback for streams whose languages
    /// the viewer never asked about.
    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        guard !preferredAudioLanguages.isEmpty else { return nil }
        guard !hasManualAudioSelection.withLock({ $0 }) else { return nil }
        return TrackLanguageMatcher.bestMatchIndex(
            in: tracks.map { TrackLanguageMatcher.Track(languageTag: $0.languageCode, label: $0.name) },
            preferring: preferredAudioLanguages
        )
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSVideoPlayer.Coordinator {
    /// The one sanctioned way to pick an audio track by hand: the
    /// preferred-audio-language pass has to stand down for the rest of the
    /// stream, which every overlay would otherwise have to remember. Callers
    /// publish their own change afterwards.
    func selectAudioTrack(_ track: MediaPlayerTrack) {
        (playerLayer?.options as? LumeKSOptions)?.noteManualAudioSelection()
        playerLayer?.player.select(track: track)
    }
}

/// Turns the user's saved KSPlayer settings into a `KSOptions` for one stream.
/// Shared by the full-screen engine view and the Multi-View tiles, which need
/// the same decoder/buffer tuning but must not claim Picture in Picture.
enum KSPlayerOptionsFactory {
    /// Process-wide KSPlayer configuration, applied exactly once on first
    /// access (static `let` init is lazy and thread-safe). These are global
    /// settings, so assigning them on every `make` call was a needless side
    /// effect from a view body.
    static let configureGlobalOptions: Void = {
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.isPipPopViewController = false

        #if DEBUG
            KSOptions.logLevel = .warning
        #else
            KSOptions.logLevel = .error
        #endif
    }()

    /// - Parameter isEmbedded: `true` for a Multi-View tile or the Guide
    ///   preview. Four tiles each allowed to start PiP from inline would fight
    ///   over the one PiP window, and a tile switching the TV's display mode
    ///   blacks out the whole screen on every zap.
    static func make(for media: PlayableMedia, isEmbedded: Bool = false) -> KSOptions {
        _ = configureGlobalOptions

        let settings = KSPlayerOptions.load()
        // System-proxy use and the primary engine are process-wide statics with
        // no per-instance counterpart, so they're applied on the type each time.
        // The layer reads `firstPlayerType` when it's created (in the view body),
        // so setting it here takes effect for this playback.
        KSOptions.useSystemHTTPProxy = settings.systemProxy
        KSOptions.firstPlayerType = settings.primaryEngine == .ffmpeg ? KSMEPlayer.self : KSAVPlayer.self

        let options = LumeKSOptions(
            preferredAudioLanguages: PlayerLanguageOptions.load().preferredAudioLanguages,
            matchesDisplayCriteria: !isEmbedded
        )
        // Now Playing metadata + remote commands are owned by
        // `NowPlayingService` for all engines; KSPlayer's built-in
        // registration would double-handle every command.
        options.registerRemoteControll = false
        options.hardwareDecode = settings.hardwareDecode
        options.asynchronousDecompression = settings.asyncDecompression
        options.isSecondOpen = settings.secondOpen
        options.isAccurateSeek = settings.accurateSeek
        options.isLoopPlay = settings.loopPlay
        options.autoDeInterlace = settings.autoDeinterlace
        options.autoRotate = settings.autoRotate
        options.videoAdaptable = settings.adaptive
        options.nobuffer = settings.noBuffer
        options.codecLowDelay = settings.codecLowDelay
        options.canStartPictureInPictureAutomaticallyFromInline = !isEmbedded && settings.autoPip
        options.autoSelectEmbedSubtitle = settings.autoSelectSubtitle
        options.maxBufferDuration = Double(settings.maxBuffer)
        options.preferredForwardBufferDuration = Double(media.isLive ? settings.liveBuffer : settings.vodBuffer)
        // Conditional: `appendHeader` writes both FFmpeg's `headers` format
        // option and `AVURLAssetHTTPHeaderFieldsKey`, so calling it
        // unconditionally would change the open path for every IPTV stream.
        if let headers = media.httpHeaders, !headers.isEmpty {
            options.appendHeader(headers)
        }
        if !media.isLive, media.startTime > 1 {
            options.startPlayTime = media.startTime
        }
        // A recording still being captured is an HLS EVENT playlist without
        // `#EXT-X-ENDLIST`, which FFmpeg's HLS demuxer treats as live and opens
        // three segments from the end. Recordings open at their first segment.
        if media.recordingTimeline != nil {
            options.formatContextOptions["live_start_index"] = 0
        }
        #if os(macOS)
            options.automaticWindowResize = false
        #endif
        return options
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    func makeOptions() -> KSOptions {
        KSPlayerOptionsFactory.make(for: media)
    }
}
