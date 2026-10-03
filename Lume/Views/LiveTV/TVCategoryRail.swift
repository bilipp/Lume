//
//  TVCategoryRail.swift
//  Lume
//
//  The tvOS Live TV category sidebar: a glass panel listing the virtual
//  collections and the provider's categories, beside the channel list or guide.
//

#if os(tvOS)
    import SwiftUI

    /// Owns the rail's `@FocusState` so focus changes here never propagate up
    /// to `TVLiveTVScreen` and rebuild the (expensive) content area.
    struct TVCategoryRail: View {
        let sections: [LiveTVSection]
        @Binding var selectedSection: LiveTVSection?
        /// Fired when the user activates (clicks) a category.
        var onCategoryActivated: () -> Void = {}
        /// Told whether focus is inside the rail, for the tab-bar entry catcher.
        @Environment(TVLiveTVFocusRegions.self) private var focusRegions: TVLiveTVFocusRegions?

        /// The focused section's id.
        @FocusState private var focused: String?
        /// Whether focus is settled inside the rail. Cleared when focus
        /// leaves, so it is already false — and rendered — before the engine
        /// hands focus back. Entry lands on the geometrically nearest
        /// category, not the selected one (`prefersDefaultFocus` can't steer
        /// the UIKit hand-off), and the snap to the selection only runs a
        /// commit later: without the pre-armed mask the wrong category
        /// flashes fully styled for that first frame.
        @State private var railOwnsFocus = false

        private let panelPadding: CGFloat = 16
        private let rowInset: CGFloat = 18
        private let iconSize: CGFloat = 22

        private var panelShape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
        }

        var body: some View {
            ScrollViewReader { proxy in
                panel(proxy)
            }
        }

        private func panel(_ proxy: ScrollViewProxy) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sections) { section in
                            categoryButton(section)
                        }
                    }
                    .padding(.horizontal, panelPadding)
                    // Room for the focused row's lift at both ends; the
                    // horizontal padding already holds it sideways.
                    .padding(.top, 4)
                    .padding(.bottom, panelPadding)
                }
                // tvOS scroll views draw outside their bounds (for focus
                // effects), so a long category list would run out of the
                // panel's bottom; it scrolls inside the glass instead.
                .clipped()
                .focusSection()
            }
            .frame(width: TVLiveTVLayout.railWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(panelShape.fill(.white.opacity(0.06)))
            .glassEffectCompat(.regular, in: panelShape)
            .overlay(panelShape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .onChange(of: focused) { _, newValue in
                guard let newValue else {
                    // A move onto a row the lazy list only just built passes
                    // through nil; only a nil that is still there a turn later
                    // means focus left the rail. Pre-arm the mask for re-entry.
                    Task { @MainActor in
                        guard focused == nil else { return }
                        railOwnsFocus = false
                        if let focusRegions, focusRegions.railFocused {
                            focusRegions.railFocused = false
                        }
                    }
                    return
                }
                if let focusRegions, !focusRegions.railFocused {
                    focusRegions.railFocused = true
                }
                if !railOwnsFocus, let selectedID = selectedSection?.id, newValue != selectedID {
                    // Entry landed on the wrong category (masked, so it never
                    // rendered styled) — snap to the selection. It may sit
                    // scrolled out of the lazy list, where a focus write finds
                    // nothing: bring it in first, then focus it a turn later.
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                    Task { @MainActor in
                        focused = selectedID
                        railOwnsFocus = true
                    }
                } else {
                    railOwnsFocus = true
                }
            }
        }

        private var header: some View {
            Text("Categories")
                .textCase(.uppercase)
                .font(.system(size: 19, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.58))
                .padding(.horizontal, panelPadding + rowInset)
                .padding(.top, panelPadding + 10)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
        }

        private func categoryButton(_ section: LiveTVSection) -> some View {
            let isSelected = selectedSection?.id == section.id
            // The selected category is exempt: when entry lands there
            // directly, it should read as focused from the first frame.
            let suppressed = !railOwnsFocus && !isSelected
            let isItemFocused = focused == section.id && !suppressed
            let rowShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            return Button {
                selectedSection = section
                onCategoryActivated()
            } label: {
                // Labels start flush at the row's edge; the virtual
                // collections' icon trails, so every label lines up whether or
                // not its row has one.
                HStack(spacing: 16) {
                    // One line at one size: provider names like
                    // "DE • Sport • Bundesliga • RAW" truncate rather than wrap,
                    // so every row keeps the same height.
                    section.titleText
                        .font(.system(
                            size: 22,
                            weight: isSelected || isItemFocused ? .semibold : .medium
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let icon = section.icon {
                        Image(systemName: icon)
                            .font(.system(size: iconSize, weight: .semibold))
                            .frame(width: iconSize)
                    }
                }
                .foregroundStyle(textColor(isFocused: isItemFocused, isSelected: isSelected))
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .padding(.horizontal, rowInset)
                .background(rowShape.fill(rowFill(isFocused: isItemFocused, isSelected: isSelected)))
                .overlay(rowShape.strokeBorder(rowBorder(isFocused: isItemFocused, isSelected: isSelected), lineWidth: 1))
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03, suppressFocusEffects: suppressed))
            .focused($focused, equals: section.id)
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private func textColor(isFocused: Bool, isSelected: Bool) -> Color {
            if isFocused { return EPGColors.ink }
            if isSelected { return .white }
            return .white.opacity(0.82)
        }

        private func rowFill(isFocused: Bool, isSelected: Bool) -> Color {
            if isFocused { return EPGColors.cardFill }
            if isSelected { return .white.opacity(0.16) }
            return .clear
        }

        private func rowBorder(isFocused: Bool, isSelected: Bool) -> Color {
            isSelected && !isFocused ? .white.opacity(0.22) : .clear
        }
    }
#endif
