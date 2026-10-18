//
//  TimelineLayoutDirection.swift
//  Lume
//

import SwiftUI

extension View {
    /// Keeps a view that lays out time left-to-right under a right-to-left
    /// locale — the SwiftUI counterpart of UIKit's `.playback` semantic
    /// content attribute. Apple leaves playback controls, scrubbers and
    /// timelines unmirrored, and on tvOS the remote's physical left/right are
    /// read as back/forward in time, which only matches the screen while the
    /// timeline runs left-to-right.
    func timelineLayoutDirection() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }
}
