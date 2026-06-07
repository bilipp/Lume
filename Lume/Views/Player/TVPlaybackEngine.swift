//
//  TVPlaybackEngine.swift
//  Lume
//
//  Engine-agnostic surface the tvOS player overlay (`TVPlayerControlsOverlay`)
//  drives. Both the VLCKit and KSPlayer coordinators conform, so the rich
//  Apple-TV-style overlay — transport, scrubber, episodes / info panels,
//  audio / subtitle menus — is shared verbatim between the two engines and
//  can't drift apart.
//

#if os(tvOS)

    import Combine
    import Foundation
    import VLCKitSPM

    /// One selectable audio or subtitle track, flattened to what the overlay's
    /// menus need. Engines map their native track types onto this so the menu
    /// code stays identical regardless of the backing player.
    struct PlayerTrackOption: Identifiable, Hashable {
        /// Opaque, engine-defined identifier handed back to `select…Track(id:)`.
        let id: String
        let label: String
        let isSelected: Bool
    }

    /// The playback surface the tvOS overlay reads and commands. Marked
    /// `@MainActor` because the overlay (a SwiftUI `View`) only ever touches it
    /// from the main actor — this lets a main-actor adapter (KSPlayer) and a
    /// nonisolated coordinator (VLCKit) both satisfy it.
    @MainActor
    protocol TVPlaybackEngine: ObservableObject {
        /// Drives the central play / pause glyph; must be published so the
        /// overlay re-renders when playback state flips.
        var isPlaying: Bool { get }

        /// Live technical characteristics of the current video track, shown in
        /// the overlay's right-hand caption and info badges. `nil` until known.
        var videoInfo: PlayerVideoInfo? { get }

        /// Selectable audio tracks (empty / single-entry hides the menu).
        var audioTrackOptions: [PlayerTrackOption] { get }
        /// Selectable subtitle tracks, excluding the implicit "Off" entry the
        /// overlay adds itself.
        var textTrackOptions: [PlayerTrackOption] { get }

        func skip(by seconds: Double)
        func seek(to seconds: TimeInterval)

        func selectAudioTrack(id: String)
        /// `nil` disables subtitles ("Off").
        func selectTextTrack(id: String?)
    }

    // MARK: - VLCKit conformance

    /// `VLCPlayerCoordinator` already exposes `isPlaying`, `videoInfo`,
    /// `skip(by:)` and `seek(to:)`; only the neutral track surface is added
    /// here. The existing `VLCMediaPlayer.Track`-typed members it keeps are
    /// still used by the iOS / macOS overlay, so nothing there changes.
    extension VLCPlayerCoordinator: TVPlaybackEngine {
        var audioTrackOptions: [PlayerTrackOption] {
            mediaPlayer.audioTracks.enumerated().map { index, track in
                PlayerTrackOption(
                    id: String(index),
                    label: track.trackName,
                    isSelected: track.isSelectedExclusively
                )
            }
        }

        var textTrackOptions: [PlayerTrackOption] {
            mediaPlayer.textTracks.enumerated().map { index, track in
                PlayerTrackOption(
                    id: String(index),
                    label: track.trackName,
                    isSelected: track.isSelectedExclusively
                )
            }
        }

        func selectAudioTrack(id: String) {
            guard let index = Int(id), mediaPlayer.audioTracks.indices.contains(index) else { return }
            mediaPlayer.audioTracks[index].isSelectedExclusively = true
            objectWillChange.send()
        }

        func selectTextTrack(id: String?) {
            guard let id else {
                mediaPlayer.deselectAllTextTracks()
                objectWillChange.send()
                return
            }
            guard let index = Int(id), mediaPlayer.textTracks.indices.contains(index) else { return }
            mediaPlayer.textTracks[index].isSelectedExclusively = true
            objectWillChange.send()
        }
    }

#endif
