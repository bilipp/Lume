//
//  LumeEngineCoordinator+AudioCodecs.swift
//  Lume
//
//  The audio codecs of the open stream, which the track menu doesn't show,
//  and the channel count the playing track asks the audio session for.
//  Split out of LumeEngineCoordinator to keep that file within the
//  project's size limit.
//

import Foundation
import LumeEngine
import OSLog

extension LumeEngineCoordinator {
    /// Hands the tracks' codecs to `onAudioCodecs` and logs them once per set:
    /// a Cast receiver plays only some of them, and a movie it can't decode
    /// casts silent.
    func logAudioCodecs(_ tracks: [TrackInfo]) {
        onAudioCodecs?(tracks.map(\.codecName))
        let codecs = tracks.map { track in
            track.audio.map { "\(track.codecName) \($0.channels)ch \($0.sampleRate)Hz" } ?? track.codecName
        }.joined(separator: " | ")
        guard codecs != loggedAudioCodecs else { return }
        loggedAudioCodecs = codecs
        Logger.player.notice("LumeEngine audio tracks: \(codecs, privacy: .public)")
    }

    /// Asks the audio session for the playing track's channel count; the
    /// engine then hands the renderer whatever width was granted. A Multiview
    /// tile or guide preview leaves the session's width alone.
    func preferAudioChannels(of track: TrackInfo?) {
        guard !isEmbedded else { return }
        PlayerAudioChannelPreference.apply(sourceChannels: track?.audio?.channels)
    }
}
