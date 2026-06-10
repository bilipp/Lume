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
import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    /// Process-wide KSPlayer configuration, applied exactly once on first
    /// access (static `let` init is lazy and thread-safe). These are global
    /// settings, so assigning them on every `makeOptions()` call was a needless
    /// side effect from a view body.
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

    func makeOptions() -> KSOptions {
        _ = Self.configureGlobalOptions

        let settings = KSPlayerOptions.load()
        // System-proxy use and the primary engine are process-wide statics with
        // no per-instance counterpart, so they're applied on the type each time.
        // The layer reads `firstPlayerType` when it's created (in the view body),
        // so setting it here takes effect for this playback.
        KSOptions.useSystemHTTPProxy = settings.systemProxy
        KSOptions.firstPlayerType = settings.primaryEngine == .ffmpeg ? KSMEPlayer.self : KSAVPlayer.self

        let options = KSOptions()
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
        options.canStartPictureInPictureAutomaticallyFromInline = settings.autoPip
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
