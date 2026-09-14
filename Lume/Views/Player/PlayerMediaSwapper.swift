//
//  PlayerMediaSwapper.swift
//  Lume
//
//  The single path an in-player transport control takes to change stream. All
//  four engine hosts (KSPlayer, VLCKit, AVPlayer, LumeEngine) drove their own
//  near-identical copy of the tvOS channel swap; the on-screen previous/next
//  controls would have added two more. This is that logic, once.
//
//  It only ever *asks* for the swap: the target is handed back to the host
//  through `onSelectMedia`, which rebuilds the engine off a changed `media`.
//  Reaching into a running engine instead re-prepares a live session, which
//  frees the demuxer context under the decode threads.
//

import Foundation
import SwiftData
import SwiftUI

/// Serialises in-player stream changes for one playback session.
///
/// One per player, owned by `FullScreenPlayerView` and handed to the engine
/// view, so every surface that can change stream — the transport buttons, a
/// macOS arrow key, the Siri Remote, the lock screen — shares one cooldown.
/// A swapper per surface would let two of them start a decoder teardown apiece
/// inside the same window, which is the shape this guards against.
///
/// Never read from a view body: nothing here invalidates a view, so the
/// playback clock stays off this object entirely.
@MainActor
final class PlayerMediaSwapper {
    /// Which end of the host-resolved neighbours a press asks for.
    enum Step {
        case previous
        case next
    }

    /// How long after an accepted swap further presses are dropped.
    ///
    /// A swap tears the decoder down and builds a new one against a fresh URL —
    /// on Stalker, a fresh `create_link` against a portal that commonly allows
    /// a single connection — and restarts the engine-fallback chain behind it.
    /// Two of those in flight is the crash shape, so presses that arrive while
    /// the last one is still landing are dropped rather than queued: queueing
    /// them would run the same teardown a beat later instead of not at all.
    static let cooldown: TimeInterval = 0.3

    private var lastSwapAt: Date?

    /// Play the neighbour on `step`'s side, if there is one and the previous
    /// swap has settled. Reports whether the stream actually changed, so a
    /// caller can keep its controls up only when something happened.
    ///
    /// `onCompleteCurrentItem` fires for an explicit step onto the next
    /// *episode* and nothing else. That press is available from the first frame,
    /// while the automatic advance arms only past `OutroTrigger`'s 90% line —
    /// where `WatchProgressWriter` has already marked the episode watched. An
    /// early press has to say so itself or the episode it left behind sits in
    /// Continue Watching forever and never scrobbles.
    @discardableResult
    func step(
        _ step: Step,
        in neighbours: PlayerItemNavigation.Neighbours,
        onCompleteCurrentItem: (() -> Void)? = nil,
        select: (PlayableMedia) -> Void
    ) -> Bool {
        let target = step == .next ? neighbours.next : neighbours.previous
        guard let target, accept() else { return false }
        if step == .next, neighbours.axis == .episode { onCompleteCurrentItem?() }
        select(target)
        // VoiceOver is otherwise told nothing: the controls auto-hide over the
        // video and the title that changed sits outside the focused element.
        AccessibilityNotification.Announcement(target.title).post()
        return true
    }

    /// Whether a swap may start now. Recorded only for swaps that go through,
    /// so a press that resolves to nothing doesn't hold up the next one.
    private func accept(at now: Date = Date()) -> Bool {
        if let lastSwapAt, now.timeIntervalSince(lastSwapAt) < Self.cooldown { return false }
        lastSwapAt = now
        return true
    }
}

#if os(tvOS)

    extension PlayerMediaSwapper {
        /// What the channel lookup needs from the host it was pressed in.
        struct LiveLookup {
            let sortRaw: String
            let restriction: ContentRestriction
            let context: ModelContext
        }

        /// Change the live channel from the Siri Remote: up/down surf to the
        /// adjacent channel the way the viewer's `LiveSurfMode` maps the press,
        /// right recalls the channel watched just before this one (the remote's
        /// "last" button). Falls back to summoning the controls when there's
        /// nothing to jump to.
        ///
        /// The direction mapping is the remote's alone — the on-screen controls
        /// take `step(_:in:)` with a literal previous/next, since a button
        /// labelled "next" that ran backwards under `.listOrder` would be a bug,
        /// not a preference.
        func surf(
            _ direction: MoveCommandDirection,
            from media: PlayableMedia,
            through lookup: LiveLookup,
            select: (PlayableMedia) -> Void,
            showControls: () -> Void
        ) {
            guard media.isLive else { return }
            let target: PlayableMedia?
            switch direction {
            case .up, .down:
                let sort = ContentSortOption(rawValue: lookup.sortRaw) ?? .playlist
                target = LiveChannelNavigator.adjacentMedia(
                    for: media, surfing: direction == .up ? .up : .down,
                    mode: .preferred,
                    sort: sort, restriction: lookup.restriction, in: lookup.context
                )
            case .right:
                target = LiveChannelHistory.recallMedia(
                    in: lookup.context, scope: media.channelScope, restriction: lookup.restriction
                )
            default:
                return
            }
            guard let target else { showControls(); return }
            guard accept() else { return }
            select(target)
            showControls()
        }
    }

#endif

#if os(macOS)

    extension View {
        /// Up/Down arrow steps one channel along the list, beside the Left/Right
        /// arrows that seek. It asks for the same swap the on-screen transport
        /// buttons do — the host-resolved neighbour through the shared swapper,
        /// debounce included — rather than resolving a channel of its own.
        ///
        /// Live TV only: `.channel` is the axis a live stream (and not a
        /// catch-up recording) carries, so during a movie or an episode the
        /// press is left to the responder chain instead of silently stepping the
        /// series, which no arrow key on this platform is labelled to do.
        func liveChannelKeyNavigation(
            neighbours: PlayerItemNavigation.Neighbours,
            swapper: PlayerMediaSwapper,
            onSelect: @escaping (PlayableMedia) -> Void,
            onResetHideTimer: @escaping () -> Void
        ) -> some View {
            onKeyPress(.upArrow) {
                channelKeyStep(.next, neighbours, swapper, onSelect, onResetHideTimer)
            }
            .onKeyPress(.downArrow) {
                channelKeyStep(.previous, neighbours, swapper, onSelect, onResetHideTimer)
            }
        }
    }

    /// A press over live TV is consumed whether or not it produced a swap: the
    /// debounce drops presses that land on the heels of the last one, and
    /// letting those through to AppKit would move focus out of the video.
    private func channelKeyStep(
        _ step: PlayerMediaSwapper.Step,
        _ neighbours: PlayerItemNavigation.Neighbours,
        _ swapper: PlayerMediaSwapper,
        _ onSelect: (PlayableMedia) -> Void,
        _ onResetHideTimer: () -> Void
    ) -> KeyPress.Result {
        guard neighbours.axis == .channel else { return .ignored }
        swapper.step(step, in: neighbours, select: onSelect)
        onResetHideTimer()
        return .handled
    }

#endif
