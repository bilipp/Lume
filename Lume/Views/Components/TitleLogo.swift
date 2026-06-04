//
//  TitleLogo.swift
//  Lume
//
//  Shows a title's TMDB wordmark logo in place of its text title, used by the
//  home hero carousel and the movie/series detail heroes (iOS, macOS, tvOS).
//

import SwiftUI

/// Shows a title's TMDB wordmark logo when one is available, gracefully falling
/// back to a styled text title while the logo loads, fails, or is absent. The
/// logo keeps its aspect ratio, capped to `maxWidth` × `maxHeight`, so it sits
/// where the text title would.
struct TitleLogo<Fallback: View>: View {
    let url: URL?
    let title: String
    var maxWidth: CGFloat = .infinity
    var maxHeight: CGFloat = 96
    var alignment: Alignment = .leading
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    // Reserve the logo's vertical space without flashing the
                    // text title first, then swapping it for the artwork.
                    Color.clear.frame(height: maxHeight)
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
                        .accessibilityLabel(title)
                case .failure:
                    fallback()
                @unknown default:
                    fallback()
                }
            }
            .frame(maxWidth: maxWidth, alignment: alignment)
        } else {
            fallback()
        }
    }
}
