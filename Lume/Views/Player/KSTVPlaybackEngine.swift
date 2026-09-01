//
//  KSTVPlaybackEngine.swift
//  Lume
//
//  Adapts `KSVideoPlayer.Coordinator` to `TVPlaybackEngine` so the KSPlayer
//  engine drives the very same tvOS overlay as VLCKit. The coordinator's
//  `state` is a computed (non-published) property and it has no `videoInfo`
//  concept, so this adapter republishes both — the host view pumps it from
//  KSPlayer's state / time callbacks.
//

#if os(tvOS)

    import AVFoundation
    import Combine
    import KSPlayer

    @MainActor
    final class KSTVPlaybackEngine: ObservableObject, TVPlaybackEngine {
        @Published private(set) var isPlaying = false
        @Published private(set) var videoInfo: PlayerVideoInfo?

        /// Weakly-held so the engine never outlives or retains the coordinator
        /// the host view owns. Set once the view mounts via `attach(coordinator:)`
        /// — keeping a default `init()` lets the host declare it as a plain
        /// `@StateObject` without an initializer-ordering dance.
        private weak var coordinator: KSVideoPlayer.Coordinator?

        init() {}

        func attach(coordinator: KSVideoPlayer.Coordinator) {
            self.coordinator = coordinator
        }

        // MARK: - Host-driven updates

        /// Recompute published state from a KSPlayer state transition.
        func syncState(_ state: KSPlayerState) {
            let playing = (state == .bufferFinished)
            if playing != isPlaying { isPlaying = playing }
            refreshVideoInfo()
        }

        /// Re-read the video track's resolution / frame rate / codec. Cheap and
        /// idempotent; only republishes when the value actually changes.
        func refreshVideoInfo() {
            let info = KSVideoInfo.resolve(from: coordinator?.playerLayer)
            if info != videoInfo { videoInfo = info }
        }

        /// Clear published state when the host swaps streams.
        func reset() {
            if isPlaying { isPlaying = false }
            if videoInfo != nil { videoInfo = nil }
        }

        // MARK: - TVPlaybackEngine

        var audioTrackOptions: [PlayerTrackOption] {
            let tracks = coordinator?.playerLayer?.player.tracks(mediaType: .audio) ?? []
            return tracks.map { track in
                PlayerTrackOption(id: String(track.trackID), label: track.name, isSelected: track.isEnabled)
            }
        }

        var textTrackOptions: [PlayerTrackOption] {
            guard let subtitleModel = coordinator?.subtitleModel else { return [] }
            let selectedID = subtitleModel.selectedSubtitleInfo?.subtitleID
            return subtitleModel.subtitleInfos.map { info in
                PlayerTrackOption(id: info.subtitleID, label: info.name, isSelected: info.subtitleID == selectedID)
            }
        }

        func skip(by seconds: Double) {
            coordinator?.skip(interval: Int(seconds))
        }

        func seek(to seconds: TimeInterval) {
            coordinator?.seek(time: seconds)
        }

        func selectAudioTrack(id: String) {
            guard let player = coordinator?.playerLayer?.player,
                  let track = player.tracks(mediaType: .audio).first(where: { String($0.trackID) == id }) else { return }
            player.select(track: track)
            objectWillChange.send()
        }

        func selectTextTrack(id: String?) {
            guard let subtitleModel = coordinator?.subtitleModel else { return }
            if let id {
                subtitleModel.selectedSubtitleInfo = subtitleModel.subtitleInfos.first { $0.subtitleID == id }
            } else {
                subtitleModel.selectedSubtitleInfo = nil
            }
            objectWillChange.send()
        }

        // MARK: - External subtitles

        /// Only while a coordinator is attached — without one there is no
        /// `SubtitleModel` to add the track to.
        var supportsExternalSubtitles: Bool {
            coordinator != nil
        }

        func loadExternalSubtitle(_ subtitle: ExternalSubtitle) {
            coordinator?.loadExternalSubtitle(subtitle)
            objectWillChange.send()
        }
    }

#endif
