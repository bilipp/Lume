//
//  PlayerAudioChannelPreference.swift
//  Lume
//
//  How many output channels the full-screen player asks the audio session for.
//
//  The request follows the audio track being played, never the route's
//  capability: asking an HDMI receiver for its full width opens a multichannel
//  PCM stream whatever the source carries, so a stereo channel reached the
//  receiver as 5.1/7.1 with silent surrounds ("Multi In") and its own stereo
//  processing never ran.
//
//  LumeEngine leaves the session to the app and only follows the negotiated
//  width. AetherEngine sets the same value itself on its renderer paths but
//  leaves the preference alone on its AVPlayer path, so the app covers that
//  one. KSPlayer and VLCKit manage their own.
//

import AVFoundation
import OSLog

enum PlayerAudioChannelPreference {
    /// The channel count to ask for: the source's own, at least stereo (a mono
    /// track is placed on both speakers), and never more than the route
    /// carries. An unknown source asks for stereo.
    nonisolated static func channels(forSource sourceChannels: Int?, routeMaximum: Int) -> Int {
        let source = sourceChannels.flatMap { $0 > 0 ? $0 : nil } ?? 2
        return min(max(2, source), max(1, routeMaximum))
    }

    /// Writes the preference for a source of `sourceChannels` (nil while no
    /// audio track is known), only when it differs from the one in place. It
    /// takes effect on an active session, so callers activate first.
    static func apply(sourceChannels: Int?) {
        #if os(iOS) || os(tvOS)
            let session = AVAudioSession.sharedInstance()
            let maximum = session.maximumOutputNumberOfChannels
            let wanted = channels(forSource: sourceChannels, routeMaximum: maximum)
            guard wanted != session.preferredOutputNumberOfChannels else { return }
            do {
                try session.setPreferredOutputNumberOfChannels(wanted)
                Logger.player.info("""
                Audio channel preference: \(wanted) (source=\(sourceChannels ?? 0) max=\(maximum) \
                output=\(session.outputNumberOfChannels))
                """)
            } catch {
                Logger.player.error("""
                Audio channel preference \(wanted) refused: \(LogRedaction.describe(error), privacy: .public)
                """)
            }
        #endif
    }
}
