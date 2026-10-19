//
//  PlayerSourceSession.swift
//  Lume
//
//  Which version of a Jellyfin/Emby title the player is playing, and the
//  picker state around it. Owned by `FullScreenPlayerView` for the life of the
//  player, so what the viewer picked carries from one episode to the next.
//
//  The flow for every stream the host makes active:
//    loading → (auto-picked) playing
//            → choosing → playing
//            → failed (no playable sources)
//  and, once playing, back to choosing when the version can't start.
//

import OSLog
import SwiftData
import SwiftUI

@Observable
final class PlayerSourceSession {
    enum Phase: Equatable {
        case idle
        case loading
        case choosing
        case playing
        case failed(String)
    }

    /// What the host hands its engine for a stream.
    enum Display {
        /// Not a Jellyfin/Emby title: the host plays the stream as it is.
        case notSourced
        /// A version is still being looked up or chosen.
        case pending
        case ready(PlayableMedia)
    }

    private(set) var phase: Phase = .idle
    private(set) var options: [MediaSourceOption] = []
    private(set) var currentOptionId: String?
    private(set) var failedIds: Set<String> = []
    /// The mid-playback picker, opened from the player's Sources control.
    var isPresentingSwitcher = false

    /// The version last picked for this title, marked in the picker. Never
    /// one the server no longer offers or that already failed this session.
    var rememberedOptionId: String? {
        guard let rememberedId, options.contains(where: { $0.id == rememberedId }),
              !failedIds.contains(rememberedId)
        else { return nil }
        return rememberedId
    }

    /// The stream the session resolved for, by `PlayableMedia.id`.
    private var mediaID: String?
    private var base: PlayableMedia?
    private var resolved: PlayableMedia?
    private var headers: [String: String]?
    /// The pick remembered when the title opened, read before this session
    /// remembers its own.
    private var rememberedId: String?
    /// The release group last played this session, for the next episode.
    private var bingeGroup: String?

    func display(for media: PlayableMedia) -> Display {
        guard JellyfinSourceResolver.itemId(for: media) != nil else { return .notSourced }
        guard phase == .playing, mediaID == media.id, let resolved else { return .pending }
        return .ready(resolved)
    }

    /// Whether the player should offer switching: only with a real choice.
    var offersSwitching: Bool {
        phase == .playing && options.count > 1
    }

    /// Whether a version that can't start has another to fall back to, so the
    /// engines report the failure here instead of showing their error.
    var canRecoverFromFailure: Bool {
        guard phase == .playing, let currentOptionId else { return false }
        return options.contains { $0.id != currentOptionId && !failedIds.contains($0.id) }
    }

    /// Looks `media`'s versions up and plays the one the rules pick, or asks.
    /// Returns `false` when `media` is not a Jellyfin/Emby title.
    func begin(for media: PlayableMedia, context: ModelContext, refresh: Bool = false) async -> Bool {
        guard JellyfinSourceResolver.itemId(for: media) != nil else { return false }
        if mediaID != media.id {
            failedIds = []
            rememberedId = MediaSourcePreferences.rememberedSourceId(for: media.contentRef)
        }
        mediaID = media.id
        base = media
        resolved = nil
        currentOptionId = nil
        options = []
        phase = .loading
        do {
            let listing = try await JellyfinSourceResolver.listing(for: media, refresh: refresh, context: context)
            guard !Task.isCancelled, mediaID == media.id else { return true }
            options = listing.options
            headers = listing.httpHeaders
        } catch JellyfinSourceResolver.ResolveError.noPlayableSources {
            guard mediaID == media.id else { return true }
            phase = .failed(JellyfinSourceResolver.ResolveError.noPlayableSources.localizedDescription)
            return true
        } catch {
            // A server that can't list versions still plays its first one at
            // the plain stream URL — exactly what happened before versions
            // were looked up at all.
            guard !Task.isCancelled, mediaID == media.id else { return true }
            let detail = (error as? JellyfinError)?.logDescription ?? LogRedaction.describe(error)
            Logger.player.error("Jellyfin PlaybackInfo failed (\(detail, privacy: .public)); playing the default source")
            resolved = media
            phase = .playing
            return true
        }
        let isEpisode = if case .episode = media.contentRef { true } else { false }
        let context = MediaSourceAutoPick.Context(
            choosesBeforePlaying: PlayerSettings.Playback.chooseSourceBeforePlaying,
            isResuming: media.startTime > 0,
            rememberedId: rememberedId,
            bingeGroup: isEpisode ? bingeGroup : nil,
            failedIds: failedIds
        )
        if let pick = MediaSourceAutoPick.pick(from: options, context: context) {
            play(pick, startTime: media.startTime)
        } else {
            phase = .choosing
        }
        return true
    }

    /// The viewer picked `option`, before playback or from the Sources
    /// control mid-stream (then `startTime` is where they were).
    func choose(_ option: MediaSourceOption, startTime: TimeInterval? = nil) {
        isPresentingSwitcher = false
        guard let base else { return }
        play(option, startTime: startTime ?? base.startTime)
    }

    /// The playing version couldn't start: mark it and ask again. `false`
    /// when there is nothing left to choose from.
    func recoverFromFailure() -> Bool {
        guard canRecoverFromFailure, let currentOptionId else { return false }
        failedIds.insert(currentOptionId)
        Logger.player.log("Jellyfin source failed to start; returning to the source picker")
        resolved = nil
        self.currentOptionId = nil
        phase = .choosing
        return true
    }

    /// Keeps the resolved stand-in in step with the host rebasing the active
    /// stream (an AirPlay engine swap), like the Stalker stand-in.
    func rebase(_ media: PlayableMedia, at position: TimeInterval) {
        guard mediaID == media.id else { return }
        base = base?.resuming(at: position)
        resolved = resolved?.resuming(at: position)
    }

    /// Every play is remembered, auto-picked or not, so the picker can mark
    /// it next time, or resuming reopens it when the picker is off.
    private func play(_ option: MediaSourceOption, startTime: TimeInterval) {
        guard let base else { return }
        resolved = JellyfinSourceResolver.media(base, playing: option, headers: headers, startTime: startTime)
        currentOptionId = option.id
        if case .episode = base.contentRef, let group = option.bingeGroup {
            bingeGroup = group
        }
        MediaSourcePreferences.remember(option.id, for: base.contentRef)
        phase = .playing
    }
}

extension EnvironmentValues {
    /// The player's source session, for the Sources control in the engine
    /// overlays; `nil` outside the full-screen player.
    @Entry var playerSourceSession: PlayerSourceSession?
}
