//
//  FullScreenPlayerView+AudioSession.swift
//  Lume
//
//  The player's global audio-session handling, split out of
//  `FullScreenPlayerView` to keep that file inside the 600-line cap.
//
//  Only LumeEngine needs this: KSPlayer and VLCKit configure `AVAudioSession`
//  themselves, so these two calls are no-ops from their point of view but must
//  still bracket every session, since the engine in use can change mid-player
//  through a fallback.
//

import AVFoundation
import OSLog

extension FullScreenPlayerView {
    func configureAudioSessionForPlayback() {
        // tvOS needs this as much as iOS: LumeEngine renders PCM through
        // AVSampleBufferAudioRenderer and sizes its downmix to the session's
        // *negotiated* output channels — without an active .playback session
        // and a matching channel preference, multichannel audio has no path.
        // (KSPlayer/VLC configure their own session; LumeEngine by design
        // does not touch global audio state, so it is the app's job.)
        #if os(iOS) || os(tvOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true, options: [])
            // Start at stereo, clearing whatever an earlier session asked
            // for. The engine widens it once it knows the audio track
            // (`PlayerAudioChannelPreference`); asking for the route's full
            // width here sent stereo channels to a receiver as 5.1.
            PlayerAudioChannelPreference.apply(sourceChannels: nil)
            let maxChannels = session.maximumOutputNumberOfChannels
            let route = session.currentRoute.outputs
                .map { "\($0.portType.rawValue)(\($0.channels?.count ?? 0)ch)" }
                .joined(separator: "+")
            Logger.player.info("""
            Audio session active: route=\(route, privacy: .public) \
            outputChannels=\(session.outputNumberOfChannels) \
            maxChannels=\(maxChannels) sampleRate=\(session.sampleRate)
            """)
        #endif
    }

    func releaseAudioSession() {
        #if os(iOS) || os(tvOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
