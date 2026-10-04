//
//  LiveChannelUnavailable.swift
//  Lume
//
//  What a live video surface shows instead of a picture: the channel's logo, or
//  "Stream unavailable" with an optional Try Again. Used by the Multi-View tiles
//  and the Live TV guide's hero preview.
//

import SwiftUI

/// A live channel's logo, falling back to an antenna glyph, sized for a dark
/// video surface.
struct LiveChannelLogoPlaceholder: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        // Never an `EmptyView` in any phase: `CachedAsyncImage` loads from a
        // `.task` on its content, which never runs on an `EmptyView`.
        CachedAsyncImage(url: url, maxPixelSize: side * 2) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fit)
            default:
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: side, height: side)
    }
}

/// "Stream unavailable" under a warning glyph and over a Try Again button,
/// or, with no retry, under the channel logo.
struct LiveChannelUnavailableBadge: View {
    let logoURL: URL?
    let logoSide: CGFloat
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if onRetry == nil {
                LiveChannelLogoPlaceholder(url: logoURL, side: logoSide)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text("Stream unavailable")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            if let onRetry {
                Button("Try Again", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(.white)
            }
        }
        .multilineTextAlignment(.center)
    }
}
