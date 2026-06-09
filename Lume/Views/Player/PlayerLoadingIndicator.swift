//
//  PlayerLoadingIndicator.swift
//  Lume
//
//  Centered spinner shown over the video host while the engine is preparing or
//  (re)buffering. KSPlayer sits in `.preparing` / `.buffering` for ~10–20s
//  before the first frame, so the host suppresses its controls and shows this
//  instead — otherwise the idle Play button reads as "paused, press me".
//

import SwiftUI

/// Centered spinner shown while the engine is preparing or (re)buffering. The
/// optional `title` is supplied only on the first open — where the dimmed
/// backdrop reads as "Loading <title>…" — and dropped for mid-stream stalls so
/// the spinner sits unobtrusively over the paused frame.
@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
struct PlayerLoadingIndicator: View {
    let title: String?

    var body: some View {
        ZStack {
            // A light dim keeps the spinner legible over a bright first frame
            // without fully hiding the video once it starts to come through.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: spacing) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(.white)
                    .scaleEffect(spinnerScale)

                if let title, !title.isEmpty {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 40)
                        .shadow(radius: 8)
                }
            }
        }
        .allowsHitTesting(false)
    }

    #if os(tvOS)
        private var spacing: CGFloat {
            36
        }

        private var spinnerScale: CGFloat {
            2.2
        }

        private var titleFont: Font {
            .system(size: 40, weight: .semibold)
        }
    #else
        private var spacing: CGFloat {
            20
        }

        private var spinnerScale: CGFloat {
            1.3
        }

        private var titleFont: Font {
            .title3.weight(.semibold)
        }
    #endif
}
