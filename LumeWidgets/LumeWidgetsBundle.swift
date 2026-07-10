//
//  LumeWidgetsBundle.swift
//  LumeWidgets
//
//  Home Screen / Desktop widgets (iOS, iPadOS, macOS). All three widgets render
//  the snapshot the app exports to the App Group container — the extension
//  never touches SwiftData or the network beyond fetching artwork.
//

import SwiftUI
import WidgetKit

@main
struct LumeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        FavoritesWidget()
        OnNowWidget()
    }
}
