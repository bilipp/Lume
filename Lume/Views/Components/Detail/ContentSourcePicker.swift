//
//  ContentSourcePicker.swift
//  Lume
//
//  Which copy of a grouped movie or series plays, asked on the detail screen
//  before the player opens. One row per catalog row: playlist, the title as
//  that playlist lists it, quality, HDR/DV and language. A Jellyfin, Emby or Plex row is a single entry; its
//  versions are picked later by the player's own source flow.
//

import SwiftUI

/// What the picker shows; presenting one opens it, nil closes it.
struct ContentSourcePickerRequest: Identifiable {
    let id = UUID()
    let title: String
    let kind: VODSourcePreferences.Kind
    let groupKey: String
    /// Best first, as `VODSourceResolver` orders them.
    let options: [VODSourceOption]
    let preselectedID: String?
    var rememberedID: String?
    var failedIDs: Set<String> = []
}

extension View {
    /// Presents `request` as a sheet (full screen on tvOS). A pick is
    /// remembered for the title on this device before `onPick` runs.
    /// `onDismiss` runs once the picker has finished animating out, the point
    /// from which a player cover can be presented without UIKit re-presenting it.
    func contentSourcePicker(
        _ request: Binding<ContentSourcePickerRequest?>,
        onDismiss: (() -> Void)? = nil,
        onPick: @escaping (VODSourceOption) -> Void
    ) -> some View {
        modifier(ContentSourcePickerHost(request: request, onDismiss: onDismiss, onPick: onPick))
    }
}

nonisolated extension VODSourceOption {
    /// `Playlist · 4K · Dolby Vision · German`; just the playlist when the
    /// title carries no tags.
    var summaryLabel: String {
        ([playlistName] + [qualityLabel].compactMap(\.self) + detailParts).joined(separator: " · ")
    }

    /// `Dolby Vision · HDR · German`, whichever the title carries.
    var detailParts: [String] {
        var parts: [String] = []
        if isDolbyVision {
            parts.append(String(localized: "Dolby Vision"))
        }
        if isHDR {
            parts.append(String(localized: "HDR"))
        }
        if let languageCode {
            parts.append(TrackLanguageMatcher.displayName(for: languageCode))
        }
        return parts
    }
}

private struct ContentSourcePickerHost: ViewModifier {
    @Binding var request: ContentSourcePickerRequest?
    let onDismiss: (() -> Void)?
    let onPick: (VODSourceOption) -> Void

    func body(content: Content) -> some View {
        content.sourcePickerPresentation(item: $request, onDismiss: onDismiss) { picker($0) }
    }

    private func picker(_ shown: ContentSourcePickerRequest) -> some View {
        ContentSourcePicker(
            request: shown,
            onPick: { option in
                VODSourcePreferences.remember(rowID: option.rowID, shown.kind, groupKey: shown.groupKey)
                request = nil
                onPick(option)
            },
            onClose: { request = nil }
        )
    }
}

struct ContentSourcePicker: View {
    let request: ContentSourcePickerRequest
    let onPick: (VODSourceOption) -> Void
    let onClose: () -> Void

    #if os(tvOS)
        @FocusState private var focusedID: String?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerSpacing) {
            header
            list
        }
        .frame(maxWidth: Metrics.maxWidth, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.top, Metrics.topPadding)
        .sourcePickerBackdrop()
        #if os(tvOS)
            .onExitCommand(perform: onClose)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: request.title)
                    .font(Metrics.titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(statusLine)
                    .font(Metrics.statusFont)
                    .foregroundStyle(request.failedIDs.isEmpty ? Color.white.opacity(0.7) : Color.orange)
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

    private var statusLine: String {
        if request.options.contains(where: { request.failedIDs.contains($0.rowID) }) {
            return String(localized: "That source didn't play. Choose another one.")
        }
        return String(localized: "Choose a source · \(request.options.count) available")
    }

    // MARK: - Rows

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Metrics.rowSpacing) {
                ForEach(request.options) { option in
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
            .defaultFocus($focusedID, initialFocusID)
            .onAppear {
                // `defaultFocus` alone doesn't take inside a freshly presented
                // cover; place focus explicitly once the rows exist.
                let id = initialFocusID
                Task { @MainActor in focusedID = id }
            }
        #endif
    }

    #if os(tvOS)
        private var initialFocusID: String? {
            if let id = request.preselectedID, request.options.contains(where: { $0.rowID == id }) {
                return id
            }
            return request.options.first { !request.failedIDs.contains($0.rowID) }?.rowID ?? request.options.first?.rowID
        }
    #endif

    @ViewBuilder
    private func row(_ option: VODSourceOption) -> some View {
        let isPreselected = option.rowID == request.preselectedID
        let button = Button { onPick(option) } label: {
            ContentSourceRow(
                option: option,
                isRemembered: option.rowID == request.rememberedID,
                hasFailed: request.failedIDs.contains(option.rowID)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPreselected ? .isSelected : [])
        #if os(tvOS)
            button
                .buttonStyle(TVContentSourceRowStyle(isPreselected: isPreselected))
                .focused($focusedID, equals: option.rowID)
        #else
            button.buttonStyle(ContentSourceRowStyle(isPreselected: isPreselected))
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
            static let statusFont = Font.subheadline
        #endif
    }
}

/// `[4K]  Playlist name`, the title as that playlist lists it, then
/// `HDR · Dolby Vision · German` when the title carries any tags.
private struct ContentSourceRow: View {
    let option: VODSourceOption
    let isRemembered: Bool
    let hasFailed: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.columnSpacing) {
            if let quality = option.qualityLabel {
                Text(verbatim: quality)
                    .font(Metrics.badgeFont)
                    .monospacedDigit()
                    .frame(minWidth: Metrics.badgeWidth)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, lineWidth: 1.5))
            }

            VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
                Text(verbatim: option.playlistName)
                    .font(Metrics.headlineFont)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: option.title)
                    .font(Metrics.detailFont)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !option.detailParts.isEmpty {
                    Text(verbatim: option.detailParts.joined(separator: " · "))
                        .font(Metrics.detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if hasFailed || isRemembered {
                    status
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var status: some View {
        if hasFailed {
            Label("Didn't play", systemImage: "exclamationmark.triangle.fill")
                .font(Metrics.detailFont.weight(.semibold))
                .foregroundStyle(.orange)
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
        #else
            static let columnSpacing: CGFloat = 14
            static let lineSpacing: CGFloat = 3
            static let badgeWidth: CGFloat = 46
            static let badgeFont = Font.caption.weight(.bold)
            static let headlineFont = Font.body.weight(.semibold)
            static let detailFont = Font.subheadline
        #endif
    }
}

#if os(tvOS)
    /// A dim full-width card that turns white with black text on focus; the
    /// preselected row carries an outline while unfocused.
    private struct TVContentSourceRowStyle: ButtonStyle {
        let isPreselected: Bool

        func makeBody(configuration: Configuration) -> some View {
            RowBody(configuration: configuration, isPreselected: isPreselected)
        }

        private struct RowBody: View {
            let configuration: ButtonStyleConfiguration
            let isPreselected: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .foregroundStyle(isFocused ? Color.black : Color.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isFocused ? Color.white : Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(isPreselected && !isFocused ? 0.6 : 0), lineWidth: 3)
                    )
                    .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1.0))
                    .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }
#else
    private struct ContentSourceRowStyle: ButtonStyle {
        let isPreselected: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.16 : (isPreselected ? 0.14 : 0.08)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(isPreselected ? 0.5 : 0), lineWidth: 1.5)
                )
                .sourceRowHoverEffect()
        }
    }
#endif

private extension View {
    /// An opaque dark backdrop; visionOS keeps the sheet's glass instead.
    @ViewBuilder
    func sourcePickerBackdrop() -> some View {
        #if os(visionOS)
            self
        #else
            ZStack {
                Color.black.ignoresSafeArea()
                self
            }
            .preferredColorScheme(.dark)
        #endif
    }

    @ViewBuilder
    func sourceRowHoverEffect() -> some View {
        #if os(iOS) || os(visionOS)
            contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14, style: .continuous))
                .hoverEffect(.highlight)
        #else
            self
        #endif
    }
}
