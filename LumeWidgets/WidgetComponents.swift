//
//  WidgetComponents.swift
//  LumeWidgets
//
//  Small building blocks shared by the three widgets.
//

import SwiftUI
import WidgetKit

/// Poster (2:3) artwork with a graceful monochrome fallback when the provider
/// has no image (or it hasn't been fetched yet).
struct ArtworkView: View {
    let image: Image?
    let kind: WidgetMediaItem.Kind
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            if let image {
                Color.clear.overlay(
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                )
            } else {
                Rectangle()
                    .fill(.quaternary)
                Image(systemName: fallbackSymbol)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var fallbackSymbol: String {
        switch kind {
        case .movie: "film"
        case .episode, .series: "tv"
        case .live: "antenna.radiowaves.left.and.right"
        }
    }
}

/// Channel logos are mostly transparent PNGs — give them padding on a subtle
/// tile so they read on any widget background.
struct ChannelLogoView: View {
    let image: Image?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Thin resume bar under continue-watching artwork.
struct ResumeBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(proxy.size.width * progress, 4))
            }
        }
        .frame(height: 4)
    }
}

/// Entry image lookup with an optional key, so views can index straight with
/// `item.imageURL`.
extension [URL: Image] {
    subscript(url: URL?) -> Image? {
        guard let url else { return nil }
        return self[url]
    }
}

/// Shown when the snapshot has no content for a widget yet.
struct WidgetEmptyView: View {
    let symbol: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
