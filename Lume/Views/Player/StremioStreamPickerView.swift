//
//  StremioStreamPickerView.swift
//  Lume
//
//  Full-screen source picker shown over the video host when a Stremio addon
//  returns more than one playable stream for a title. Addons differentiate
//  their candidates by quality, size and provider (encoded in each stream's
//  `name`/`description`), so the viewer picks one before the engine loads —
//  mirroring the stream list the official Stremio app shows on every play.
//

import SwiftUI

/// Scrollable list of an addon's stream candidates, in the addon's own
/// preference order. `onSelect` starts playback with the chosen stream;
/// `onClose` leaves the player without playing.
@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
struct StremioStreamPickerView: View {
    /// The title being played, so the header reads "choosing for <title>".
    let title: String?
    let options: [StremioStreamOption]
    let onSelect: (StremioStreamOption) -> Void
    let onClose: () -> Void

    #if os(tvOS)
        @FocusState private var focusedOption: Int?
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // No video is coming through behind the picker; a solid backdrop
            // keeps the long release names legible.
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: headerSpacing) {
                header
                list
            }
            .padding(.top, topPadding)

            #if !os(tvOS)
                closeButton
            #endif
        }
        #if os(tvOS)
        // Menu backs out of the picker (and the player) rather than falling
        // through to the engine that hasn't started yet.
        .onExitCommand(perform: onClose)
        .onAppear { focusedOption = options.first?.id }
        #endif
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Choose a Source")
                .font(headerFont)
                .foregroundStyle(.white)

            if let title, !title.isEmpty {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 40)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: rowSpacing) {
                ForEach(options) { option in
                    row(for: option)
                }
            }
            .frame(maxWidth: listWidth)
            .padding(.horizontal, 40)
            .padding(.vertical, rowSpacing)
        }
        .scrollClipDisabled()
    }

    private func row(for option: StremioStreamOption) -> some View {
        Button {
            onSelect(option)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(option.name ?? String(localized: "Stream \(option.id + 1)"))
                        .font(rowTitleFont)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let size = option.videoSize, size > 0 {
                        Text(size.formatted(.byteCount(style: .file)))
                            .font(rowDetailFont)
                            .foregroundStyle(.secondary)
                    }
                }

                if let details = option.details, !details.isEmpty {
                    Text(details)
                        .font(rowDetailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(detailLineLimit)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            #if !os(tvOS)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(.card)
        .focused($focusedOption, equals: option.id)
        #else
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        #endif
    }

    #if !os(tvOS)
        private var closeButton: some View {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close player")
            .keyboardShortcut(.escape, modifiers: [])
        }
    #endif

    // MARK: - Platform metrics

    #if os(tvOS)
        private var headerSpacing: CGFloat {
            36
        }

        private var topPadding: CGFloat {
            60
        }

        private var rowSpacing: CGFloat {
            24
        }

        private var listWidth: CGFloat {
            1100
        }

        private var detailLineLimit: Int {
            3
        }

        private var headerFont: Font {
            .system(size: 44, weight: .bold)
        }

        private var titleFont: Font {
            .system(size: 30, weight: .medium)
        }

        private var rowTitleFont: Font {
            .system(size: 28, weight: .semibold)
        }

        private var rowDetailFont: Font {
            .system(size: 22)
        }
    #else
        private var headerSpacing: CGFloat {
            20
        }

        private var topPadding: CGFloat {
            28
        }

        private var rowSpacing: CGFloat {
            10
        }

        private var listWidth: CGFloat {
            640
        }

        private var detailLineLimit: Int {
            4
        }

        private var headerFont: Font {
            .title2.weight(.bold)
        }

        private var titleFont: Font {
            .subheadline.weight(.medium)
        }

        private var rowTitleFont: Font {
            .subheadline.weight(.semibold)
        }

        private var rowDetailFont: Font {
            .caption
        }
    #endif
}
