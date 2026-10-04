//
//  LeagueCrest.swift
//  Lume
//
//  A competition crest with a fallback glyph, shared by the sports cards and
//  detail headers.
//

import SwiftUI

/// A competition crest at `size`, with a court glyph while it loads or when
/// the provider sent none.
struct LeagueCrest: View {
    let url: URL?
    var size: CGFloat

    var body: some View {
        CachedAsyncImage(url: url, maxPixelSize: size * 2) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "sportscourt")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
