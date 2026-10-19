//
//  MediaSourcePickerView.swift
//  Lume
//
//  The version picker for a Jellyfin/Emby title: shown by the player in place
//  of its loading screen before playback, and as a sheet from the Sources
//  control mid-stream. Each row leads with a headline built from the parsed
//  release — resolution, tags, size, cached — then where it comes from, then
//  the server's own label for it.
//

import SwiftUI

struct MediaSourcePickerView: View {
    let title: String
    let subtitle: String?
    let options: [MediaSourceOption]
    let isLoading: Bool
    let currentId: String?
    let failedIds: Set<String>
    /// The version last picked for this title, before playback starts.
    var rememberedId: String?
    /// Set when the lookup found nothing playable; replaces the list.
    var failureMessage: String?
    var onRetry: (() -> Void)?
    let onPick: (MediaSourceOption) -> Void
    let onClose: () -> Void

    #if os(tvOS)
        @FocusState private var focusedId: String?
        @FocusState private var retryFocused: Bool
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Metrics.headerSpacing) {
                header
                if isLoading {
                    loading
                } else if failureMessage != nil {
                    retry
                } else {
                    list
                }
            }
            .frame(maxWidth: Metrics.maxWidth, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.top, Metrics.topPadding)
        }
        .preferredColorScheme(.dark)
        #if os(tvOS)
            .onExitCommand(perform: onClose)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Metrics.titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Metrics.subtitleFont)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(statusLine)
                    .font(Metrics.statusFont)
                    .foregroundStyle(isWarning ? Color.orange : Color.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            #if !os(tvOS)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            #endif
        }
    }

    private var isWarning: Bool {
        failureMessage != nil || (!failedIds.isEmpty && currentId == nil)
    }

    private var statusLine: String {
        if let failureMessage {
            return failureMessage
        }
        if isLoading {
            return String(localized: "Finding sources…")
        }
        // Mid-stream something is playing, so a failed row is history.
        if !failedIds.isEmpty, currentId == nil {
            return String(localized: "That source didn't play. Choose another one.")
        }
        return String(localized: "Choose a source · \(options.count) available")
    }

    private var loading: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.large)
            .tint(.white)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }

    @ViewBuilder
    private var retry: some View {
        if let onRetry {
            let button = Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            #if os(tvOS)
                button
                    .focused($retryFocused)
                    .onAppear { Task { @MainActor in retryFocused = true } }
            #else
                button
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.2))
            #endif
        }
    }

    // MARK: - Rows

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Metrics.rowSpacing) {
                ForEach(options) { option in
                    row(option)
                }
            }
            // Room inside the clip for a focused row's lift and shadow.
            .padding(.vertical, Metrics.listVerticalPadding)
            .padding(.horizontal, Metrics.listHorizontalPadding)
        }
        // …while the rows stay aligned with the header.
        .padding(.horizontal, -Metrics.listHorizontalPadding)
        #if os(tvOS)
            .onAppear {
                // `defaultFocus` alone doesn't take inside a freshly swapped
                // player body; place focus explicitly once the rows exist.
                let preferredId = currentId ?? rememberedId
                let first = options.first { $0.id == preferredId } ?? options.first { !failedIds.contains($0.id) }
                Task { @MainActor in focusedId = first?.id }
            }
        #endif
    }

    @ViewBuilder
    private func row(_ option: MediaSourceOption) -> some View {
        let button = Button { onPick(option) } label: {
            MediaSourceRow(
                option: option, isCurrent: option.id == currentId,
                isRemembered: option.id == rememberedId, hasFailed: failedIds.contains(option.id)
            )
        }
        .accessibilityElement(children: .combine)
        #if os(tvOS)
            button
                .buttonStyle(TVSourceRowStyle())
                .focused($focusedId, equals: option.id)
        #else
            button.buttonStyle(SourceRowStyle())
        #endif
    }

    // MARK: - Metrics

    private enum Metrics {
        #if os(tvOS)
            static let maxWidth: CGFloat = 1200
            static let horizontalPadding: CGFloat = 80
            static let topPadding: CGFloat = 60
            static let headerSpacing: CGFloat = 32
            static let rowSpacing: CGFloat = 16
            static let listVerticalPadding: CGFloat = 24
            static let listHorizontalPadding: CGFloat = 24
            static let titleFont = Font.system(size: 48, weight: .bold)
            static let subtitleFont = Font.system(size: 28, weight: .medium)
            static let statusFont = Font.system(size: 26, weight: .regular)
        #else
            static let maxWidth: CGFloat = 760
            static let horizontalPadding: CGFloat = 20
            static let topPadding: CGFloat = 20
            static let headerSpacing: CGFloat = 20
            static let rowSpacing: CGFloat = 10
            static let listVerticalPadding: CGFloat = 4
            static let listHorizontalPadding: CGFloat = 0
            static let titleFont = Font.title2.weight(.bold)
            static let subtitleFont = Font.subheadline.weight(.medium)
            static let statusFont = Font.subheadline
        #endif
    }
}

/// One version: `[4K]  REMUX · HDR10 · TrueHD   62.1 GB ⚡`, then the
/// provider, then the server's label.
private struct MediaSourceRow: View {
    let option: MediaSourceOption
    let isCurrent: Bool
    let isRemembered: Bool
    let hasFailed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.columnSpacing) {
            Text(option.resolution ?? "—")
                .font(Metrics.badgeFont)
                .monospacedDigit()
                .frame(minWidth: Metrics.badgeWidth)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, lineWidth: 1.5))

            VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(headline)
                        .font(Metrics.headlineFont)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let size = option.sizeBytes {
                        Text(size.formatted(.byteCount(style: .file)))
                            .font(Metrics.detailFont)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    cacheGlyph
                }
                if let provider = option.provider {
                    Text(provider)
                        .font(Metrics.detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let label = option.label {
                    Text(label)
                        .font(Metrics.labelFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(Metrics.labelLines)
                        .multilineTextAlignment(.leading)
                }
                if isCurrent || isRemembered || hasFailed {
                    status
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Non-breaking hyphens keep a tag such as `E-AC-3` on one line when the
    /// headline wraps.
    private var headline: String {
        guard !option.tags.isEmpty else { return String(localized: "Source") }
        return option.tags.joined(separator: " · ").replacingOccurrences(of: "-", with: "\u{2011}")
    }

    @ViewBuilder
    private var cacheGlyph: some View {
        switch option.isCached {
        case true:
            Image(systemName: "bolt.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Cached")
        case false:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not cached")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var status: some View {
        if hasFailed {
            Label("Didn't play", systemImage: "exclamationmark.triangle.fill")
                .font(Metrics.detailFont.weight(.semibold))
                .foregroundStyle(.orange)
        } else if isCurrent {
            Label("Playing", systemImage: "checkmark")
                .font(Metrics.detailFont.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            // Secondary follows the row's text, so it reads on a focused
            // white tvOS row too.
            Label("Last Used", systemImage: "clock.arrow.circlepath")
                .font(Metrics.detailFont.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private enum Metrics {
        #if os(tvOS)
            static let columnSpacing: CGFloat = 24
            static let lineSpacing: CGFloat = 6
            static let badgeWidth: CGFloat = 80
            static let badgeFont = Font.system(size: 24, weight: .bold)
            static let headlineFont = Font.system(size: 30, weight: .semibold)
            static let detailFont = Font.system(size: 24)
            static let labelFont = Font.system(size: 20)
            static let labelLines = 2
        #else
            static let columnSpacing: CGFloat = 14
            static let lineSpacing: CGFloat = 3
            static let badgeWidth: CGFloat = 46
            static let badgeFont = Font.caption.weight(.bold)
            static let headlineFont = Font.body.weight(.semibold)
            static let detailFont = Font.subheadline
            static let labelFont = Font.caption
            static let labelLines = 3
        #endif
    }
}

#if os(tvOS)
    /// Glass-free list row for the ten-foot picker: a dim card that turns white
    /// with black text on focus, like the player's other focus targets.
    private struct TVSourceRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            RowBody(configuration: configuration)
        }

        private struct RowBody: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .foregroundStyle(isFocused ? Color.black : Color.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isFocused ? Color.white : Color.white.opacity(0.08))
                    )
                    .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1.0))
                    .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }
#else
    private struct SourceRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
                )
        }
    }
#endif
