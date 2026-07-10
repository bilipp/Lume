//
//  FullScreenPlayerView+AudioSession.swift
//  Lume
//
//  The player host's global audio-session handling, split out of
//  FullScreenPlayerView to keep that file within the project's line-count cap.
//

import AVFoundation
import OSLog
import SwiftUI

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
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
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
