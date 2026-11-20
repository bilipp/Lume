//
//  AetherEngineCoordinator+TrackCarry.swift
//  Lume
//
//  Carrying the viewer's subtitle pick into the next load (the next episode,
//  or a reload of the same stream). Split out of AetherEngineCoordinator to
//  keep that file within the project's size limit; the matching itself lives
//  in `TrackCarryOver`.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    extension AetherEngineCoordinator {
        /// Re-applies the carried subtitle pick once the engine lists the
        /// stream's own tracks. A sidecar the viewer picked for this stream
        /// wins over it.
        func applyCarriedSubtitle(on session: LumeAetherSession) {
            guard hasPendingCarriedSubtitle else { return }
            guard !isExternalSubtitleSelected else {
                hasPendingCarriedSubtitle = false
                return
            }
            let tracks = session.subtitleTracks.filter { !$0.isExternal }
            if tracks.isEmpty, trackCarry.subtitle != .off { return }
            hasPendingCarriedSubtitle = false
            switch trackCarry.resolveSubtitle(in: tracks.map { .init(track: Self.carryTrack($0), isForced: $0.isForced) }) {
            case .keep:
                return
            case .off:
                guard session.activeSubtitleTrackID != nil else { return }
                session.selectSubtitleTrack(id: nil)
                subtitleCues.clear()
            case let .select(position):
                let id = tracks[position].id
                guard session.activeSubtitleTrackID != id else { return }
                session.selectSubtitleTrack(id: id)
            }
        }

        /// The carry for a subtitle menu pick. The sidecar file belongs to
        /// this stream alone, so it doesn't carry.
        func carriedSubtitle(forTrackID index: Int?) -> TrackCarryOver.Subtitle? {
            guard let index else { return .off }
            guard let track = session?.subtitleTracks.first(where: { $0.id == index }), !track.isExternal else {
                return nil
            }
            return .track(Self.carryTrack(track), isForced: track.isForced)
        }

        static func carryTrack(_ track: LumeAetherTrack) -> TrackLanguageMatcher.Track {
            TrackLanguageMatcher.Track(languageTag: track.language, label: track.name.isEmpty ? nil : track.name)
        }
    }

#endif
