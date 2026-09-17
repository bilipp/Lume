//
//  AVPlayerCoordinator+Languages.swift
//  Lume
//
//  The viewer's preferred audio languages, applied to an AVPlayer item once
//  its media-selection groups load. Split out of AVPlayerCoordinator to keep
//  that file within the project's size limit.
//

import AVFoundation
import Foundation

extension AVPlayerCoordinator {
    /// Apply the viewer's ordered audio-language preference to a freshly loaded
    /// item, once its media-selection groups are known.
    ///
    /// The list is empty by default, and that path returns before anything is
    /// selected — playback then is exactly what AVFoundation would have chosen
    /// on its own. Not `private`: called from `loadTracks` in
    /// AVPlayerCoordinator.swift.
    func applyPreferredLanguages(to item: AVPlayerItem) {
        guard !hasManualTrackSelection else { return }
        let audioLanguages = languageOptions.preferredAudioLanguages
        guard !audioLanguages.isEmpty else { return }

        let audio = selectPreferredAudio(in: item, preferring: audioLanguages)

        // Subtitles already on (the system's caption preferences, or a stream
        // that forces them) are left exactly as they are: this feature never
        // re-points a track the viewer can already see.
        guard let legibleGroup,
              item.currentMediaSelection.selectedMediaOption(in: legibleGroup) == nil
        else { return }
        enableForcedSubtitles(
            in: item,
            group: legibleGroup,
            under: audio,
            audioLanguages: audioLanguages
        )
    }

    /// Select the preferred audio option, and report the option playback will
    /// actually use — the preferred one when the stream carries it, otherwise
    /// whatever AVFoundation had already settled on. `nil` when the stream
    /// advertises no audible selection group.
    private func selectPreferredAudio(
        in item: AVPlayerItem,
        preferring languages: [String]
    ) -> AVMediaSelectionOption? {
        guard let audioGroup else { return nil }
        let current = item.currentMediaSelection.selectedMediaOption(in: audioGroup) ?? audioGroup.defaultOption
        // No match means the stream carries none of the viewer's languages:
        // leave the container's own choice alone rather than settle for the
        // first track.
        guard let chosen = Self.bestOption(from: audioOptions, preferring: languages) else { return current }
        item.select(chosen, in: audioGroup)
        return chosen
    }

    /// The one case where subtitles turn themselves on: the audio the viewer
    /// will hear is foreign to their preferred audio languages and the stream
    /// carries a forced track for the untranslated dialogue. Unreachable while
    /// the preferred-audio list is empty — nothing is foreign then.
    private func enableForcedSubtitles(
        in item: AVPlayerItem,
        group: AVMediaSelectionGroup,
        under audio: AVMediaSelectionOption?,
        audioLanguages: [String]
    ) {
        guard let audio,
              TrackLanguageMatcher.isForeign(Self.matcherTrack(audio), comparedTo: audioLanguages)
        else { return }
        let forced = legibleOptions.filter { $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        guard let fallback = forced.first else { return }
        // Preferred audio order first — someone who asked for German audio
        // reads German signs — then whatever forced track the mux author
        // expected to be shown.
        let chosen = Self.bestOption(from: forced, preferring: audioLanguages) ?? fallback
        item.select(chosen, in: group)
    }

    /// The option best satisfying an ordered language preference, or `nil` when
    /// the stream carries none of those languages.
    ///
    /// AVFoundation's own filter runs first — it resolves regional variants the
    /// way the rest of the system does — and the shared matcher then breaks the
    /// ties it leaves, so a commentary or audio-description track loses to a
    /// plain track of the same language here exactly as on the other engines.
    private static func bestOption(
        from options: [AVMediaSelectionOption],
        preferring languages: [String]
    ) -> AVMediaSelectionOption? {
        guard !languages.isEmpty else { return nil }
        let candidates = AVMediaSelectionGroup.mediaSelectionOptions(
            from: options,
            filteredAndSortedAccordingToPreferredLanguages: languages
        )
        guard let first = candidates.first else { return nil }
        let index = TrackLanguageMatcher.bestMatchIndex(in: candidates.map(matcherTrack), preferring: languages)
        return index.map { candidates[$0] } ?? first
    }

    private nonisolated static func matcherTrack(_ option: AVMediaSelectionOption) -> TrackLanguageMatcher.Track {
        TrackLanguageMatcher.Track(languageTag: languageTag(of: option), label: option.displayName)
    }
}
