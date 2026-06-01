//
//  PlatformNavigationTitle.swift
//  Lume
//
//  Applies a navigation title on iOS but suppresses the large title text on
//  tvOS, where the custom tab bar already conveys the active section.
//

import SwiftUI

extension View {
    /// Sets the navigation title on platforms that benefit from it, while
    /// omitting the large title text on tvOS.
    func platformNavigationTitle(_ title: LocalizedStringKey) -> some View {
        #if os(tvOS)
            self
        #else
            navigationTitle(title)
        #endif
    }
}
