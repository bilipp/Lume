//
//  LumeEngineEngineView+Navigation.swift
//  Lume
//
//  The on-screen previous/next transport step for the LumeEngine host, kept out
//  of the main file (which is at its length cap). tvOS reaches the same swapper
//  from the Siri Remote instead — see `switchLiveChannel`.
//

import SwiftUI

#if !os(tvOS)

    extension LumeEngineEngineView {
        /// Play the episode or channel on `step`'s side. Goes through the shared
        /// swapper — which drops a press that lands on the heels of the last one
        /// — and back out to the host, the only place allowed to change the
        /// stream: re-preparing this session in place frees the demuxer context
        /// under the decode threads.
        func stepItem(_ step: PlayerMediaSwapper.Step) {
            mediaSwapper.step(
                step,
                in: itemNeighbours,
                onCompleteCurrentItem: { onCompleteCurrentItem?() },
                select: { onSelectMedia?($0) }
            )
        }
    }

#endif
