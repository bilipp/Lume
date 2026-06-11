//
//  PlayerErrorIndicator.swift
//  Lume
//
//  Centered failure state shown over the video host when a stream never starts
//  (or drops permanently mid-playback). It replaces the loading spinner once the
//  startup watchdog fires or the bounded reconnect budget is spent, so a dead
//  stream surfaces a "Try Again / Back" choice instead of locking the player on
//  an endless spinner.
//

import SwiftUI

/// Centered "playback failed" overlay. `title` is the stream name (shown so the
/// viewer knows which stream failed); `onRetry` re-prepares the stream in place
/// and `onClose` leaves the player.
@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
struct PlayerErrorIndicator: View {
    let title: String?
    let onRetry: () -> Void
    let onClose: () -> Void

    #if os(tvOS)
        @FocusState private var retryFocused: Bool
    #endif

    var body: some View {
        ZStack {
            // A heavier dim than the loading spinner: there is no video coming
            // through behind it, so the message should read clearly.
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: spacing) {
                Image(systemName: "wifi.exclamationmark")
                    .font(iconFont)
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text("Playback Failed")
                        .font(titleFont)
                        .foregroundStyle(.white)

                    if let title, !title.isEmpty {
                        Text(title)
                            .font(streamFont)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text("This stream couldn’t be loaded. It may be offline or temporarily unavailable.")
                        .font(messageFont)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: maxTextWidth)
                }

                buttons
                    .padding(.top, buttonTopPadding)
            }
            .padding(.horizontal, 40)
            .shadow(radius: 8)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        #if os(tvOS)
            HStack(spacing: 28) {
                Button(action: onRetry) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.system(size: 24, weight: .semibold))
                }
                .buttonStyle(TVGlassButtonStyle())
                .focused($retryFocused)

                Button(action: onClose) {
                    Label("Back", systemImage: "xmark")
                        .font(.system(size: 24, weight: .semibold))
                }
                .buttonStyle(TVGlassButtonStyle())
            }
            .frame(width: 720)
            .onAppear { retryFocused = true }
            // Menu on the failure overlay leaves the player, matching the Back
            // button, rather than falling through to the engine.
            .onExitCommand(perform: onClose)
        #else
            HStack(spacing: 14) {
                glassButton("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                glassButton("Back", systemImage: "xmark", action: onClose)
            }
        #endif
    }

    #if !os(tvOS)
        private func glassButton(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Label(titleKey, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    #endif

    // MARK: - Platform metrics

    #if os(tvOS)
        private var spacing: CGFloat {
            30
        }

        private var iconFont: Font {
            .system(size: 80, weight: .regular)
        }

        private var titleFont: Font {
            .system(size: 40, weight: .semibold)
        }

        private var streamFont: Font {
            .system(size: 26, weight: .regular)
        }

        private var messageFont: Font {
            .system(size: 24, weight: .regular)
        }

        private var maxTextWidth: CGFloat {
            760
        }

        private var buttonTopPadding: CGFloat {
            20
        }
    #else
        private var spacing: CGFloat {
            18
        }

        private var iconFont: Font {
            .system(size: 44, weight: .regular)
        }

        private var titleFont: Font {
            .title2.weight(.semibold)
        }

        private var streamFont: Font {
            .subheadline
        }

        private var messageFont: Font {
            .footnote
        }

        private var maxTextWidth: CGFloat {
            360
        }

        private var buttonTopPadding: CGFloat {
            12
        }
    #endif
}
