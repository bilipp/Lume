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

extension FullScreenPlayerView {
    func configureAudioSessionForPlayback() {
        // tvOS needs this as much as iOS: LumeEngine renders PCM through
        // AVSampleBufferAudioRenderer and sizes its downmix to the session's
        // *negotiated* output channels — without an active .playback session
        // the route stays at its default and multichannel audio has no path.
        // (KSPlayer/VLC configure their own session; LumeEngine by design
        // does not touch global audio state, so it is the app's job.)
        PlaybackAudioRoute.activateForPlayback()
    }

    func releaseAudioSession() {
        PlaybackAudioRoute.release()
    }
}
