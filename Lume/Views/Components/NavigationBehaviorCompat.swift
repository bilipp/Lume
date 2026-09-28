//
//  NavigationBehaviorCompat.swift
//  Lume
//
//  iOS 26 introduced the minimizing tab bar behaviour. This helper applies it
//  on iOS 26+ and no-ops on iOS 18.
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
    }
#endif
