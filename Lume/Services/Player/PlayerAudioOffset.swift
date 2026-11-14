//
//  PlayerAudioOffset.swift
//  Lume
//
//  The audio offset: how far the sound is shifted against the picture, in
//  milliseconds, positive playing audio later. A provider whose streams
//  carry sound ahead of or behind the picture gets a default on its
//  `Playlist`; the player can nudge it for the running session and save the
//  nudge back as that provider's default.
//
//  Every engine takes the value in its own unit and sign, so the mappers
//  live here, next to the presets, and the coordinators only apply them:
//  VLCKit in microseconds, KSPlayer as a *video* delay with the opposite
//  sign (its FFmpeg clock sync shows the frame at `clock - videoDelay`, so a
//  negative video delay is audio arriving later), and AetherEngine in
//  seconds on top of its own engine-wide delay setting.
//

import Foundation
import SwiftData
import SwiftUI

/// The pickable offsets and the per-engine conversions.
nonisolated enum AudioOffsetPreset {
    /// Milliseconds; positive plays audio later.
    static let values = [-500, -400, -300, -200, -150, -100, -50, 0, 50, 100, 150, 200, 300, 400, 500]

    /// AetherEngine carries at most ±2 s (`AudioDelayPolicy.maxAbsSeconds`);
    /// the other engines take more, but nothing a viewer wants.
    static let maxAbsMilliseconds = 2000

    static func clamped(_ milliseconds: Int) -> Int {
        min(max(milliseconds, -maxAbsMilliseconds), maxAbsMilliseconds)
    }

    static func label(_ milliseconds: Int) -> String {
        milliseconds > 0 ? "+\(milliseconds) ms" : "\(milliseconds) ms"
    }

    /// `VLCMediaPlayer.currentAudioPlaybackDelay`: microseconds, positive
    /// delays the audio.
    static func vlcMicroseconds(_ milliseconds: Int) -> Int {
        clamped(milliseconds) * 1000
    }

    /// `KSOptions.videoDelay`: seconds the *video* is held back. Audio later
    /// by `milliseconds` is the picture earlier by the same amount.
    static func ksPlayerVideoDelaySeconds(_ milliseconds: Int) -> Double {
        -Double(clamped(milliseconds)) / 1000
    }

    /// AetherEngine's `audioDelaySeconds`: the engine-wide delay from its own
    /// settings plus the offset, clamped to what the engine carries.
    static func aetherSeconds(engineMilliseconds: Int, offsetMilliseconds: Int) -> Double {
        Double(clamped(engineMilliseconds + offsetMilliseconds)) / 1000
    }
}

/// The offset in force for the full-screen player: the provider's default
/// from the media, the viewer's nudge for this session on top, and whether
/// the engine on screen can take a change while playing.
///
/// Owned by `FullScreenPlayerView` for the life of the player, like
/// `PlayerSourceSession`, so the nudge survives an engine fallback (which
/// rebuilds the engine view) and carries to the next episode or channel of
/// the same provider. A zap to another provider's channel drops it: the
/// offset corrects that provider's streams, not the viewer's room.
@Observable
final class PlayerAudioOffsetSession {
    /// The provider's default, from `PlayableMedia.audioOffsetMilliseconds`.
    private(set) var providerMilliseconds = 0
    /// The viewer's pick for this session, or `nil` to follow the provider.
    private(set) var sessionMilliseconds: Int?
    /// The playlist the playing item belongs to, by the id prefix every
    /// synced catalog row carries. `nil` for a recording or a hand-built id.
    private(set) var ownerPlaylistID: UUID?
    /// The engine that can apply a change while playing, or `nil` while the
    /// one on screen can't (AVPlayer, LumeEngine, KSPlayer's AVPlayer path).
    private(set) var adjustingEngine: PlayerEngineKind?

    var isAdjustable: Bool {
        adjustingEngine != nil
    }

    var effectiveMilliseconds: Int {
        sessionMilliseconds ?? providerMilliseconds
    }

    /// Whether the session plays at a value other than the provider's.
    var hasSessionOverride: Bool {
        guard let sessionMilliseconds else { return false }
        return sessionMilliseconds != providerMilliseconds
    }

    /// Called for every stream the host makes active.
    func update(for media: PlayableMedia) {
        let owner = Self.ownerPlaylistID(of: media)
        if owner != ownerPlaylistID {
            sessionMilliseconds = nil
        }
        ownerPlaylistID = owner
        providerMilliseconds = AudioOffsetPreset.clamped(media.audioOffsetMilliseconds ?? 0)
    }

    func select(_ milliseconds: Int) {
        let clamped = AudioOffsetPreset.clamped(milliseconds)
        sessionMilliseconds = clamped == providerMilliseconds ? nil : clamped
    }

    func useProviderDefault() {
        sessionMilliseconds = nil
    }

    /// Writes the value in force onto the owning playlist, so every stream
    /// of that provider starts with it. Returns `false` when the playing
    /// item has no playlist to write to.
    @discardableResult
    func saveAsProviderDefault(in context: ModelContext) -> Bool {
        guard let ownerPlaylistID, let playlist = PlaylistOwner.playlist(withID: ownerPlaylistID, in: context) else {
            return false
        }
        let value = effectiveMilliseconds
        playlist.audioOffsetMilliseconds = value
        providerMilliseconds = value
        sessionMilliseconds = nil
        return true
    }

    /// An engine view reports whether its running player takes a change.
    /// Keyed by engine so the view a fallback tears down can't clear what
    /// its replacement just registered.
    func register(engine: PlayerEngineKind, isAdjustable: Bool) {
        if isAdjustable {
            adjustingEngine = engine
        } else if adjustingEngine == engine {
            adjustingEngine = nil
        }
    }

    func unregister(engine: PlayerEngineKind) {
        if adjustingEngine == engine {
            adjustingEngine = nil
        }
    }

    private static func ownerPlaylistID(of media: PlayableMedia) -> UUID? {
        switch media.contentRef {
        case let .movie(id), let .episode(id), let .live(id):
            PlaylistOwner.declaredOwner(of: id)
        case .recording:
            nil
        }
    }
}

extension EnvironmentValues {
    /// `nil` outside the full-screen player.
    @Entry var playerAudioOffset: PlayerAudioOffsetSession?
}
