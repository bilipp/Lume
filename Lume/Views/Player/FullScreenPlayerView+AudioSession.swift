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
        // the route stays at its default and multichannel audio has no path.
        // (KSPlayer/VLC configure their own session; LumeEngine by design
        // does not touch global audio state, so it is the app's job.)
        #if os(iOS) || os(tvOS)
            let session = AVAudioSession.sharedInstance()
            session.setMoviePlaybackCategory()
            // Ask for the route's full width (HDMI LPCM surround); harmless
            // when the route is stereo — the session clamps and LumeEngine
            // downmixes to whatever was actually granted.
            let maxChannels = session.maximumOutputNumberOfChannels
            if maxChannels > 2 {
                try? session.setPreferredOutputNumberOfChannels(maxChannels)
            }
            try? session.setActive(true, options: [])
            let route = session.currentRoute.outputs
                .map { "\($0.portType.rawValue)(\($0.channels?.count ?? 0)ch)" }
                .joined(separator: "+")
            Logger.player.info("""
            Audio session active: route=\(route, privacy: .public) \
            policy=\(session.routeSharingPolicy.rawValue) \
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

#if os(iOS) || os(tvOS)
    extension AVAudioSession {
        /// `.playback` / `.moviePlayback`, on tvOS with the long-form route
        /// sharing policy.
        ///
        /// On tvOS the HomePods picked in Control Center (a multi-room group, or
        /// the TV's default speakers) are the shared long-form route; a session
        /// on the default policy was heard on only one of two HomePods. KSPlayer
        /// sets this policy itself; LumeEngine leaves the session to us.
        /// `.longFormVideo` is unavailable on tvOS, hence `.longFormAudio`, which
        /// takes no category options. iOS stays on the default policy: there,
        /// AirPlay hands playback to AVPlayer.
        func setMoviePlaybackCategory() {
            #if os(tvOS)
                try? setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio, options: [])
            #else
                try? setCategory(.playback, mode: .moviePlayback, options: [])
            #endif
        }
    }
#endif
