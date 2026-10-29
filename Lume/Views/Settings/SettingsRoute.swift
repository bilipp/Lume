//
//  SettingsRoute.swift
//  Lume
//
//  A Settings page another surface (the quick-switch overlay) opens Settings
//  on, carried by `DeepLinkRouter.pendingSettingsRoute`.
//

/// A Settings page another surface opens Settings on.
enum SettingsRoute: Hashable {
    case playlists
    case combinedView

    /// The pages pushed to reach this one, root first, so Back walks up the
    /// hierarchy rather than closing Settings.
    var stack: [SettingsRoute] {
        switch self {
        case .playlists: [.playlists]
        case .combinedView: [.playlists, .combinedView]
        }
    }
}
