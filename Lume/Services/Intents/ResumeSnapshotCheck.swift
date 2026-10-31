//
//  ResumeSnapshotCheck.swift
//  Lume
//
//  Whether the stream `PlaybackResumeStore` would reopen is still allowed for
//  the profile active now. The snapshot is one global key, written by whoever
//  played last, so a Siri resume re-checks it rather than trusting it.
//

import Foundation
import SwiftData

enum ResumeSnapshotCheck {
    /// The catalog link a snapshot is checked through. A recording has none:
    /// it isn't a catalog item.
    nonisolated static func catalogLink(for ref: PlayableMedia.ContentRef) -> DeepLink? {
        switch ref {
        case let .movie(id): .playMovie(id: id)
        case let .episode(id): .playEpisode(id: id)
        case let .live(id): .playLive(id: id)
        case .recording: nil
        }
    }

    /// Whether `media` may be reopened for the viewer `restriction` describes.
    /// A recording carries no category to check a child profile against, so a
    /// child never gets one.
    static func allows(
        _ media: PlayableMedia,
        in context: ModelContext,
        restriction: ContentRestriction,
        isPremium: Bool? = nil
    ) -> Bool {
        guard let link = catalogLink(for: media.contentRef) else { return !restriction.isActive }
        return WidgetLinkResolver.resolve(link, in: context, restriction: restriction, isPremium: isPremium) != nil
    }

    /// Whether a `.resume` can go ahead. A player already up needs no check:
    /// the link only brings it forward.
    static func canResume(in context: ModelContext, restriction: ContentRestriction) -> Bool {
        guard NowPlayingService.shared.currentMedia == nil else { return true }
        guard let media = PlaybackResumeStore.load() else { return false }
        return allows(media, in: context, restriction: restriction)
    }
}
