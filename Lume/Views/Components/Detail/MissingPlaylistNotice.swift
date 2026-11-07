//
//  MissingPlaylistNotice.swift
//  Lume
//
//  Shown where playback would start when the item's id names no installed
//  playlist. Playing it from any other playlist would send the request with
//  the wrong provider's credentials, so the screen says why it can't play.
//

import SwiftUI

struct MissingPlaylistNotice: View {
    var body: some View {
        Label {
            Text("This item's playlist could not be found.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        #if os(tvOS)
        .font(.system(size: 24, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
        #else
        .font(.footnote)
        .foregroundStyle(.secondary)
        #endif
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Stacks a `MissingPlaylistNotice` under a detail screen's Play button
    /// while the item's owning playlist can't be resolved.
    func missingPlaylistNotice(_ isMissing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self
            if isMissing {
                MissingPlaylistNotice()
            }
        }
    }
}

#Preview {
    MissingPlaylistNotice()
        .padding()
}
