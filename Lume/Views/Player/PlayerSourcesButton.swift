//
//  PlayerSourcesButton.swift
//  Lume
//
//  The in-player Sources control shared by the KSPlayer, VLCKit, AVPlayer and
//  LumeEngine overlays on iOS, macOS and visionOS (tvOS draws its own button
//  in `TVPlayerControlsOverlay+Sources.swift`). Shown only while the playing
//  Jellyfin/Emby title offers more than one version; it opens the host's
//  mid-stream picker and never reads the playback clock.
//

import SwiftUI

struct PlayerSourcesButton: View {
    var onResetHideTimer: () -> Void

    @Environment(\.playerSourceSession) private var session

    var body: some View {
        if let session, session.offersSwitching {
            Button {
                session.isPresentingSwitcher = true
                onResetHideTimer()
            } label: {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sources")
            .help("Sources")
        }
    }
}
