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
        /// The Recordings entry, below the virtual collections and above the
        /// first category; nil hides it.
        var recordings: TVCategoryRailRecordingsEntry?
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
        /// The pending "focus left the rail" verdict, cancelled when focus
        /// lands on a row again before it runs.
        @State private var exitCheck: Task<Void, Never>?

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        rows
                    }
                    // The same inset on every side, so the first category
                    // sits in the panel's corner like the rest of the rows;
                    // it also holds the focused row's lift.
                    .padding(panelPadding)
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
            .onChange(of: recordings == nil) { _, isHidden in
                if isHidden { recordingsEntryRemoved(proxy) }
            }
            .onChange(of: focused) { _, newValue in
                exitCheck?.cancel()
                guard let newValue else {
                    // A move onto a row the lazy list only just built passes
                    // through nil — for several frames while the list is
                    // swiped through fast, so a single turn isn't enough: read
                    // as an exit, the next row snapped focus back to the
                    // selection. Only a nil that outlasts the build means focus
                    // left the rail; re-entry takes another press, well after.
                    // Pre-arm the mask for it.
                    exitCheck = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, focused == nil else { return }
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
                if !railOwnsFocus, let selectedID, newValue != selectedID {
                    // Entry landed on the wrong category (masked, so it never
                    // rendered styled) — snap to the selection. It may sit
                    // scrolled out of the lazy list, where a focus write finds
                    // nothing: bring it in first (only as far as needed, so a
                    // visible selection doesn't move), then focus it a turn
                    // later. The mask stays on until focus reaches it — lifted
                    // any earlier, the landing row starts its focus fade and
                    // flashes. Should the engine refuse the write, it lifts
                    // anyway so the rail never stays masked.
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo(selectedID)
                    }
                    Task { @MainActor in
                        focused = selectedID
                        try? await Task.sleep(for: .milliseconds(300))
                        if !railOwnsFocus {
                            railOwnsFocus = true
                        }
                    }
                } else {
                    railOwnsFocus = true
                }
            }
        }

        /// Visual order is focus order: Favorites and Recently Watched
        /// (whichever exist), Recordings, then the provider's categories.
        @ViewBuilder
        private var rows: some View {
            let pinnedCount = sections.prefix(while: \.isVirtual).count
            ForEach(sections.prefix(pinnedCount)) { section in
                categoryButton(section)
            }
            if let recordings {
                recordingsButton(recordings)
            }
            ForEach(sections.dropFirst(pinnedCount)) { section in
                categoryButton(section)
            }
        }

        /// The entry went away under focus (turned off in Settings or the
        /// server unpaired): hand focus to the selected category rather than
        /// leaving the engine to pick a row.
        private func recordingsEntryRemoved(_ proxy: ScrollViewProxy) {
            guard focused == TVCategoryRailRecordingsEntry.id, let selectedID else { return }
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(selectedID)
            }
            Task { @MainActor in focused = selectedID }
        }

        /// The row that reads as selected: Recordings while its library shows,
        /// else the selected category.
        private var selectedID: String? {
            recordings?.isSelected == true ? TVCategoryRailRecordingsEntry.id : selectedSection?.id
        }

        private func categoryButton(_ section: LiveTVSection) -> some View {
            railButton(id: section.id, title: section.titleText, icon: section.icon) {
                selectedSection = section
                onCategoryActivated()
            }
        }

        private func recordingsButton(_ entry: TVCategoryRailRecordingsEntry) -> some View {
            railButton(
                id: TVCategoryRailRecordingsEntry.id,
                title: Text("Recordings"),
                icon: entry.isLocked ? "crown" : "recordingtape",
                action: entry.onActivate
            )
            // Outside the ForEach, so the snap to the selection needs an id
            // to scroll to.
            .id(TVCategoryRailRecordingsEntry.id)
        }

        private func railButton(id: String, title: Text, icon: String?, action: @escaping () -> Void) -> some View {
            let isSelected = selectedID == id
            // The selected category is exempt: when entry lands there
            // directly, it should read as focused from the first frame.
            let suppressed = !railOwnsFocus && !isSelected
            let isItemFocused = focused == id && !suppressed
            let rowShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            return Button(action: action) {
                // Labels start flush at the row's edge; the virtual
                // collections' icon trails, so every label lines up whether or
                // not its row has one.
                HStack(spacing: 16) {
                    // One line at one size: provider names like
                    // "DE • Sport • Bundesliga • RAW" truncate rather than wrap,
                    // so every row keeps the same height.
                    title
                        .font(.system(
                            size: 22,
                            weight: isSelected || isItemFocused ? .semibold : .medium
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let icon {
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
            .focused($focused, equals: id)
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

    /// The Recordings row under the virtual collections, shown while a
    /// recording server is paired and Settings › Live TV lists it in the rail.
    /// Locked (no Lume Pro) it carries the crown.
    struct TVCategoryRailRecordingsEntry {
        static let id = "lume.liveSection.recordings"

        let isSelected: Bool
        let isLocked: Bool
        let onActivate: () -> Void
    }
#endif
