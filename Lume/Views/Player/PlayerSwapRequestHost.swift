//
//  PlayerSwapRequestHost.swift
//  Lume
//
//  Lets an open full-screen player pick up a `PlayerSwapRequests` request.
//  A modifier rather than a read in the player's body, so a request arriving
//  doesn't re-render the whole player host.
//

import SwiftUI

extension View {
    /// Hands each stream asked for through `PlayerSwapRequests.shared` to
    /// `apply`, which swaps it in through the player's own swap path and
    /// reports whether the swap was accepted. macOS swaps through
    /// `MacPlayerWindowRouter` instead, so nothing is posted there.
    func appliesPlayerSwapRequests(_ apply: @escaping (PlayableMedia) -> Bool) -> some View {
        #if os(macOS)
            self
        #else
            modifier(PlayerSwapRequestHost(apply: apply))
        #endif
    }
}

private struct PlayerSwapRequestHost: ViewModifier {
    let apply: (PlayableMedia) -> Bool

    @State private var requests = PlayerSwapRequests.shared
    @State private var retry: Task<Void, Never>?

    private static let retryMargin: Duration = .milliseconds(50)

    func body(content: Content) -> some View {
        content
            .onChange(of: requests.pending) { _, request in
                retry?.cancel()
                retry = nil
                guard request != nil, !requests.deliver(apply) else { return }
                // Turned away inside `PlayerMediaSwapper.cooldown`: one more try
                // once it has elapsed, so the request isn't lost to a swap
                // that landed just before it.
                let requests = requests
                let apply = apply
                retry = Task {
                    try? await Task.sleep(for: .seconds(PlayerMediaSwapper.cooldown) + Self.retryMargin)
                    guard !Task.isCancelled else { return }
                    requests.deliver(apply)
                }
            }
            .onDisappear {
                retry?.cancel()
                retry = nil
            }
    }
}
