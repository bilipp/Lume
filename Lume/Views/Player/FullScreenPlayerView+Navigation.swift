//
//  FullScreenPlayerView+Navigation.swift
//  Lume
//
//  What the player's previous/next transport controls play. The host resolves
//  this once per stream, in `.task(id: activeMedia.id)`, and hands the answer
//  down to whichever engine is driving playback: resolving it in a body would
//  put a SwiftData fetch on the main actor every time the controls re-render,
//  and three of the four overlays re-render on the playback clock.
//

import SwiftData
import SwiftUI

extension FullScreenPlayerView {
    /// Previous/next stream for `media` — the surrounding episodes of a series,
    /// or the channels either side of a live one.
    ///
    /// `restriction` is threaded in rather than defaulted, like
    /// `LiveChannelNavigator.adjacentMedia`: a permissive default here would let
    /// a child profile step into a category a parent locked (see PR #162).
    static func resolveNeighbours(
        for media: PlayableMedia,
        sortRaw: String,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> PlayerItemNavigation.Neighbours {
        PlayerItemNavigation.neighbours(
            for: media,
            sort: ContentSortOption(rawValue: sortRaw) ?? .playlist,
            restriction: restriction,
            in: context
        )
    }

    /// The episode auto-advance and `PlayerNextUpOverlay` queue after the active
    /// stream, taken from the neighbours already resolved rather than re-walking
    /// the series: `NextEpisodeResolver` faults the playing episode and its
    /// siblings, which is not work to do twice per swap. `nil` for anything but
    /// an episode — movies and live channels have nothing queued behind them.
    static func queuedEpisode(from neighbours: PlayerItemNavigation.Neighbours) -> PlayableMedia? {
        neighbours.axis == .episode ? neighbours.next : nil
    }
}

// MARK: - Swapping the active stream

extension FullScreenPlayerView {
    /// Persist the outgoing stream's progress, then swap in a new one. Every
    /// in-player move — a picked episode, a channel step, auto-advance — goes
    /// through here: the engines rebuild off `activeMedia` changing, and
    /// reaching into their state directly instead re-prepares a running session
    /// (a use-after-free in KSPlayer's decode threads).
    func switchMedia(to newMedia: PlayableMedia) {
        guard newMedia.id != activeMedia.id else { return }
        // Flush the outgoing stream's progress before the clock resets — capture
        // happens synchronously inside `persistProgressDetached`.
        persistProgressDetached(force: true)
        // The completion claim covers exactly that one flush. Left standing, a
        // step back onto the same episode would never record progress again.
        completedRef = nil
        clock.reset()
        // Restart the fallback chain from the primary engine for the new stream.
        engineAttempt = 0
        activeMedia = newMedia
        // Slide the outgoing channel into the recall slot so `right` can jump back.
        LiveChannelHistory.record(newMedia)
    }

    /// What `MPRemoteCommandCenter`'s next/previous track buttons do, handed to
    /// the engine so it rides along on the `Transport` it attaches.
    ///
    /// Owned here rather than built by the engine: an engine attaches its
    /// transport once and stays mounted across swaps, while what "next" plays
    /// changes with every one of them. This closure reads the host's state when
    /// it is pressed, so it never goes stale behind the stream on screen.
    ///
    /// `nil` on tvOS, which drives stream changes from the Siri Remote's own
    /// mapping and keeps the surface it has.
    var remoteAdvanceHandler: ((PlayerMediaSwapper.Step) -> Bool)? {
        #if os(tvOS)
            nil
        #else
            { advanceForRemoteCommand($0) }
        #endif
    }

    /// Play the neighbouring stream because a remote command asked for it —
    /// next/previous track on the lock screen, in Control Center, or on a
    /// headset. Reports whether anything played, so the command centre can
    /// answer `.noSuchContent` at the end of a series or a channel list.
    ///
    /// Same path as the on-screen buttons: the swapper drops a press that lands
    /// on the heels of the last one, marks an episode left behind by an explicit
    /// "next" watched, and announces the new title to VoiceOver.
    func advanceForRemoteCommand(_ step: PlayerMediaSwapper.Step) -> Bool {
        mediaSwapper.step(
            step,
            in: itemNeighbours,
            onCompleteCurrentItem: { completeActiveEpisode() },
            select: { switchMedia(to: $0) }
        )
    }

    /// Mark the episode on screen watched because the viewer explicitly asked
    /// for the next one, before the swap takes the clock away.
    ///
    /// The transport button is available from the first frame, deliberately —
    /// it is not armed by `OutroTrigger`, whose 90% line is what
    /// `WatchProgressWriter` measures completion against. So an explicit press
    /// has to record the intent itself: left to the progress write, an episode
    /// skipped at 20 minutes would sit in Continue Watching forever and never
    /// scrobble. Auto-advance is untouched — it only fires past that same line,
    /// where the episode is already watched.
    ///
    /// The swap that follows this call flushes the outgoing stream's progress,
    /// and `writer` is an actor: without claiming the ref here, that flush
    /// would record the position the viewer skipped *from* and land after the
    /// completion, leaving the episode unwatched and unscrobbled — the exact
    /// outcome this function exists to prevent.
    func completeActiveEpisode() {
        guard case .episode = activeMedia.contentRef, let writer = progressWriter else { return }
        let ref = activeMedia.contentRef
        let total = clock.duration
        completedRef = ref
        let previous = pendingProgressWrite
        pendingProgressWrite = Task { @MainActor in
            // Ordered, not raced: whatever was already in flight for this
            // stream settles first, so the completion is the last word.
            await previous?.value
            let completion = await writer.markWatched(ref: ref, duration: total)
            WatchProgressBuffer.remove(ref: ref)
            if let completion {
                syncTraktWatched(ref: completion.ref)
                AppStoreReviewPrompt.shared.noteCompletedTitle()
            }
        }
    }

    /// Rebase the active stream to resume at `position`. Also rebases the
    /// Stalker-resolved stand-in: it shares `activeMedia`'s id, so `displayMedia`
    /// keeps returning it (and `.task(id:)` won't re-resolve) — without this the
    /// engine taking over would start from the stand-in's stale `startTime`.
    func resumeActiveMedia(at position: TimeInterval) {
        activeMedia = activeMedia.resuming(at: position)
        if let resolved = resolvedMedia, resolved.id == activeMedia.id {
            resolvedMedia = resolved.resuming(at: position)
        }
    }
}
