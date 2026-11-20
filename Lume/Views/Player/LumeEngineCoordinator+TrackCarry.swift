//
//  LumeEngineCoordinator+TrackCarry.swift
//  Lume
//
//  Carrying the viewer's subtitle pick into the next session (the next
//  episode, or a stall reload of the same stream). Split out of
//  LumeEngineCoordinator to keep that file within the project's size limit;
//  the matching itself lives in `TrackCarryOver`.
//

import Foundation
import LumeEngine

extension LumeEngineCoordinator {
    /// Reads back the subtitle a session just opened on, then re-applies the
    /// carried subtitle pick to it. The engine starts with subtitles off
    /// unless it turned a forced track on for foreign audio.
    ///
    /// After `open`, unlike the audio pick: the engine has no subtitle
    /// preference to resolve while it builds the pipeline. Selecting attaches
    /// the lane through a backfill seek to the playhead, which is still 0
    /// before the first frame, so a resume position is sought again after it.
    /// Skipped on a live source that could seek at all — most live endpoints
    /// do not survive one.
    func syncSubtitleSelection(on session: PlayerSession, info: MediaInfo, media: PlayableMedia) async {
        selectedSubtitleID = await session.selectedSubtitleTrackIndex.map { String($0) }
        guard !media.isLive || !info.isSeekable else { return }
        let tracks = info.subtitleTracks.filter { $0.index != TrackInfo.embeddedClosedCaptionsIndex }
        let index: Int32?
        switch trackCarry.resolveSubtitle(in: tracks.map { .init(track: Self.carryTrack($0), isForced: $0.isForced) }) {
        case .keep:
            return
        case .off:
            index = nil
        case let .select(position):
            index = tracks[position].index
        }
        let id = index.map { String($0) }
        guard id != selectedSubtitleID else { return }
        await session.selectSubtitleTrack(index)
        selectedSubtitleID = id
        if index != nil, media.startTime > 1, !media.isLive, info.isSeekable {
            await session.seek(to: media.startTime)
        }
    }

    /// The carry for a subtitle menu pick. The sidecar file and the captions
    /// riding in the video belong to this stream alone, so neither carries.
    func carriedSubtitle(forTrackID id: String?) -> TrackCarryOver.Subtitle? {
        guard let id else { return .off }
        guard let index = Int32(id), index != TrackInfo.embeddedClosedCaptionsIndex,
              let track = mediaInfo?.subtitleTracks.first(where: { $0.index == index })
        else { return nil }
        return .track(Self.carryTrack(track), isForced: track.isForced)
    }

    static func carryTrack(_ track: TrackInfo) -> TrackLanguageMatcher.Track {
        TrackLanguageMatcher.Track(languageTag: track.language, label: track.title)
    }
}
