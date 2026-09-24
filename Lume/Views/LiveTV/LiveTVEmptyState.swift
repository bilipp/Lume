//
//  LiveTVEmptyState.swift
//  Lume
//
//  The Live TV browse empty state, phrased for the active playlist's source.
//

import SwiftUI

/// A WebDAV playlist is a tree of media files on a file share — it can never
/// carry live channels, so the generic "sync to load channels" copy would send
/// the user into an endless re-sync loop. Same for the media servers, whose
/// Live TV tuner APIs are not synced.
struct LiveTVEmptyState: View {
    let sourceType: PlaylistSourceType?

    var body: some View {
        if sourceType == .webdav {
            ContentUnavailableView(
                "No Live Channels",
                systemImage: "folder",
                description: Text("This WebDAV share has no live channels — it carries movies and series only.")
            )
        } else if sourceType?.isMediaServer == true {
            ContentUnavailableView(
                "No Live Channels",
                systemImage: "folder",
                description: Text("This server has no live channels here — it carries movies and series only.")
            )
        } else {
            ContentUnavailableView(
                "No Channels",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Sync your playlist to load live TV channels")
            )
        }
    }
}
