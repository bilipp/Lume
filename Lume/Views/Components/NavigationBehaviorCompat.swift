//
//  NavigationBehaviorCompat.swift
//  Lume
//
//  iOS 26 introduced the minimizing tab bar and compact search toolbar
//  behaviours. These helpers apply them on iOS 26+ and no-op on iOS 18.
//

import SwiftUI

#if os(iOS)
    extension View {
        /// Minimizes the tab bar on scroll down (iOS 26+); no-op on earlier systems.
        @ViewBuilder
        func tabBarMinimizeOnScrollDownIfAvailable() -> some View {
            if #available(iOS 26, *) {
                tabBarMinimizeBehavior(.onScrollDown)
            } else {
                self
            }
        }

        /// Uses the minimizing (expand-on-tap) search toolbar (iOS 26+); no-op on earlier systems.
        @ViewBuilder
        func searchToolbarMinimizeIfAvailable() -> some View {
            if #available(iOS 26, *) {
                searchToolbarBehavior(.minimize)
            } else {
                self
            }
        }
    }
#endif
