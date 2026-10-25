//
//  LumeWidgetsBundle.swift
//  LumeWidgets
//
//  Home Screen widgets plus the download Live Activity.
//  The Home Screen widgets render the snapshot the app exports to the App Group
//  container — the extension never touches SwiftData or the network beyond
//  fetching artwork.
//

import SwiftUI
import WidgetKit

@main
struct LumeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        FavoritesWidget()
        OnNowWidget()
        DownloadLiveActivity()
    }
}
