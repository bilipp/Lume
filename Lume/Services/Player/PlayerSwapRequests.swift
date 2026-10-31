//
//  PlayerSwapRequests.swift
//  Lume
//
//  A stream an outside caller wants the open full-screen player to switch to.
//  Presenting a second player over the first would stack two engines, two
//  audio sessions and two Now Playing publishers, so a request made while a
//  player is up lands here and the player applies it through its own swap
//  path. macOS keeps its one-window equivalent, `MacPlayerWindowRouter`.
//

import Foundation
import Observation

@MainActor
@Observable
final class PlayerSwapRequests {
    static let shared = PlayerSwapRequests()

    /// One request. The id lets the same stream be asked for twice in a row.
    struct Request: Equatable {
        let id = UUID()
        let media: PlayableMedia
    }

    /// The request no player has taken yet. A newer one replaces it.
    private(set) var pending: Request?

    func request(_ media: PlayableMedia) {
        pending = Request(media: media)
    }

    /// Offers the waiting stream to `apply` and clears it only once `apply`
    /// reports the player took it, so a request turned away by the swap
    /// cooldown stays for a retry. Reports whether it was applied.
    @discardableResult
    func deliver(_ apply: (PlayableMedia) -> Bool) -> Bool {
        guard let request = pending, apply(request.media) else { return false }
        if pending == request { pending = nil }
        return true
    }
}
