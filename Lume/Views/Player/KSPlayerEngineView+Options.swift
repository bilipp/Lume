//
//  KSPlayerEngineView+Options.swift
//  Lume
//
//  Builds the `KSOptions` for a playback session from the user's saved KSPlayer
//  settings (see `KSPlayerOptions`). Split out of `KSPlayerEngineView` to keep
//  that view file focused on the SwiftUI body.
//

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

    init(preferredAudioLanguages: [String]) {
        self.preferredAudioLanguages = preferredAudioLanguages
        super.init()
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

    /// - Parameter allowsPictureInPicture: `false` for a Multi-View tile — four
    ///   tiles each allowed to start PiP from inline would fight over the one
    ///   PiP window.
    static func make(for media: PlayableMedia, allowsPictureInPicture: Bool = true) -> KSOptions {
        _ = configureGlobalOptions

        let settings = KSPlayerOptions.load()
        // System-proxy use and the primary engine are process-wide statics with
        // no per-instance counterpart, so they're applied on the type each time.
        // The layer reads `firstPlayerType` when it's created (in the view body),
        // so setting it here takes effect for this playback.
        KSOptions.useSystemHTTPProxy = settings.systemProxy
        KSOptions.firstPlayerType = settings.primaryEngine == .ffmpeg ? KSMEPlayer.self : KSAVPlayer.self

        let options = LumeKSOptions(
            preferredAudioLanguages: PlayerLanguageOptions.load().preferredAudioLanguages
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
        options.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture && settings.autoPip
        options.autoSelectEmbedSubtitle = settings.autoSelectSubtitle
        options.maxBufferDuration = Double(settings.maxBuffer)
        options.preferredForwardBufferDuration = Double(media.isLive ? settings.liveBuffer : settings.vodBuffer)
        if !media.isLive, media.startTime > 1 {
            options.startPlayTime = media.startTime
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
