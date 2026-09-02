//
//  CatchupBadge.swift
//  Lume
//
//  Shared catch-up (archive) affordance for channel rows and cells
//

import SwiftUI

/// The archive affordance every channel row and cell shows. Callers apply their
/// own font and tint.
struct CatchupBadge: View {
    /// `nil` where the depth is unknown or the caller wants the glyph alone —
    /// see `PlayableMedia.archiveBadgeDays(for:)`.
    let days: Int?
    var spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: "clock.arrow.circlepath")
                .accessibilityLabel(Text("Catch-up available"))
            if let days {
                Text("Catchup: \(days)d")
            }
        }
    }
}

#Preview("Catch-up badge") {
    VStack(alignment: .leading, spacing: 8) {
        CatchupBadge(days: 7)
        CatchupBadge(days: nil)
    }
    .font(.caption2)
    .foregroundStyle(.blue)
    .padding()
}
