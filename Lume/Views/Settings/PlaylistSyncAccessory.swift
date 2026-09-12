//
//  PlaylistSyncAccessory.swift
//  Lume
//
//  The small trailing indicator a playlist row draws when its sync needs
//  attention — and draws nothing at all when it doesn't. Shared by the iOS /
//  macOS settings list and the tvOS playlist row so the two can't drift.
//

import SwiftUI

/// Trailing accessory for a playlist row: a spinner while syncing, a glyph for
/// the states worth surfacing, and nothing for a playlist that is fine.
///
/// The empty case is the important one. A row that badges every state teaches
/// the eye to skip the badge, so the healthy majority stays silent and the
/// accessory only ever means "look at this one".
struct PlaylistSyncAccessory: View {
    let state: PlaylistSyncState
    /// Point size of the glyph. tvOS rows are far larger than an iOS list cell,
    /// so the caller sets this rather than the view guessing from the platform.
    var size: CGFloat = 15

    var body: some View {
        switch state {
        case .syncing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text(state.statusLabel))
        case .failed, .never:
            if let symbolName = state.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: size))
                    .foregroundStyle(state.tint)
                    .accessibilityLabel(Text(state.statusLabel))
            }
        case .overdue, .synced, .disabled:
            EmptyView()
        }
    }
}
