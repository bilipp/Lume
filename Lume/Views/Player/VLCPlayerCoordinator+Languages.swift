//
//  VLCPlayerCoordinator+Languages.swift
//  Lume
//
//  The viewer's preferred audio languages, applied to the VLCKit player once
//  libvlc has parsed the stream's tracks, plus the manual picks that outrank
//  them. Split out of VLCPlayerCoordinator to keep that file within the
//  project's size limit.
//

import Combine
import Foundation
import VLCKit

extension VLCPlayerCoordinator {
    // MARK: - Tracks

    var audioTracks: [VLCMediaPlayer.Track] {
        mediaPlayer.audioTracks
    }

    var textTracks: [VLCMediaPlayer.Track] {
        mediaPlayer.textTracks
    }

    /// Manual audio pick. Outranks the preferred audio language for the rest of
    /// this stream, including across the rebuilds a reconnect or a Try Again
    /// performs.
    func selectAudioTrack(_ track: VLCMediaPlayer.Track) {
        hasManualTrackSelection = true
        track.isSelectedExclusively = true
        objectWillChange.send()
    }

    /// Manual subtitle pick; `nil` is "Off".
    func selectTextTrack(_ track: VLCMediaPlayer.Track?) {
        hasManualTrackSelection = true
        if let track {
            track.isSelectedExclusively = true
        } else {
            mediaPlayer.deselectAllTextTracks()
        }
        objectWillChange.send()
    }

    // MARK: - Preferred languages

    /// Apply the viewer's ordered audio-language preference to the tracks
    /// libvlc has parsed.
    ///
    /// Driven from `mediaPlayerStateChanged(_:)`'s main hop: tracks arrive
    /// asynchronously and the coordinator implements no track-added callback,
    /// so there is no earlier hook. The one-shot flag is set only once audio
    /// tracks actually exist — the state change fires on every transition and
    /// libvlc parses elementary streams progressively, so latching earlier
    /// would skip the pass for the whole stream. It also stops the pass
    /// fighting the viewer's later picks.
    ///
    /// The list is empty by default and that path returns before touching the
    /// player, so selection stays exactly what libvlc chose.
    ///
    /// There is no forced-subtitle branch: `VLCMediaTrack` carries no forced
    /// disposition, so the rule the other engines apply when the audio turns
    /// out foreign cannot be evaluated on VLCKit.
    ///
    /// Not `private`: called from VLCPlayerCoordinator.swift.
    func applyPreferredLanguagesIfNeeded() {
        guard !didApplyPreferredLanguages, !hasManualTrackSelection else { return }
        let audioLanguages = languageOptions.preferredAudioLanguages
        guard !audioLanguages.isEmpty else { return }

        let tracks = mediaPlayer.audioTracks
        guard !tracks.isEmpty else { return }
        didApplyPreferredLanguages = true

        // No match means the stream carries none of the viewer's languages:
        // leave libvlc's own choice alone rather than settle for the first
        // track.
        guard let index = TrackLanguageMatcher.bestMatchIndex(
            in: tracks.map(Self.matcherTrack),
            preferring: audioLanguages
        ), !tracks[index].isSelectedExclusively else { return }
        tracks[index].isSelectedExclusively = true
        objectWillChange.send()
    }

    private nonisolated static func matcherTrack(_ track: VLCMediaPlayer.Track) -> TrackLanguageMatcher.Track {
        TrackLanguageMatcher.Track(languageTag: track.language, label: track.trackName)
    }
}
