//
//  TVSidebarRail.swift
//  Lume
//
//  The tvOS glass sidebar beside a content pane — Live TV's categories and
//  Settings' categories. Moving focus only highlights a row; Select runs it.
//  Focus entering the rail always lands on the selected row.
//

#if os(tvOS)
    import SwiftUI

    /// One row of a `TVSidebarRail`.
    struct TVSidebarRailItem: Identifiable {
        let id: String
        let title: Text
        /// Trails the title; nil leaves the row without one.
        var icon: String?
        let action: () -> Void
    }

    /// Owns the rail's `@FocusState` so focus changes here never propagate up
    /// to the screen and rebuild its (possibly expensive) content pane.
    struct TVSidebarRail: View {
        static let width: CGFloat = 340
        /// The gap between the rail and the pane beside it.
        static let paneSpacing: CGFloat = 32

        /// The rows, in focus order.
        let items: [TVSidebarRailItem]
        /// The row that reads as selected, and the one entry snaps to.
        let selectedID: String?
        /// Bumped to move focus onto the selected row from outside the rail —
        /// Menu from the content pane, or an entry catcher.
        var focusRequest = 0
        /// Bumped as the screen sends focus from a row into its pane. A pane
        /// with nothing focusable refuses it, and the engine then drops focus
        /// on some other row (the first); treated as an entry, that landing is
        /// masked and snapped back to the selected row.
        var focusHandOffRequest = 0
        /// Draws every row unfocused and leaves focus where it lands — for
        /// focus only passing through the rail on its way into the pane.
        var masksFocus = false
        /// Told when focus settles into (`true`) or out of (`false`) the rail.
        var onFocusChange: (Bool) -> Void = { _ in }

        /// The focused row's id.
        @FocusState private var focused: String?
        /// Whether focus is settled inside the rail. Cleared when focus
        /// leaves, so it is already false — and rendered — before the engine
        /// hands focus back. Entry lands on the geometrically nearest row,
        /// not the selected one (`prefersDefaultFocus` can't steer the UIKit
        /// hand-off), and the snap to the selection only runs a commit later:
        /// without the pre-armed mask the wrong row flashes fully styled for
        /// that first frame.
        @State private var railOwnsFocus = false
        /// Set by `focusHandOffRequest` until focus has left or the pane has
        /// had its chance. Meanwhile the selected row keeps its focused look
        /// while focus is anywhere in the rail, so a refused hand-off's detour
        /// to another row doesn't blink it.
        @State private var handOffPending = false
        /// The pending "focus left the rail" verdict, cancelled when focus
        /// lands on a row again before it runs.
        @State private var exitCheck: Task<Void, Never>?
        /// The panel in window coordinates, to tell focus that left the rail
        /// from focus parked on its scroll view's fast-scroll index.
        @State private var panelFrame: CGRect = .zero

        private let panelPadding: CGFloat = 16
        private let rowInset: CGFloat = 18
        private let iconSize: CGFloat = 22

        private var panelShape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
        }

        private var itemIDs: [String] {
            items.map(\.id)
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
                    // The same inset on every side, so the first row sits in
                    // the panel's corner like the rest of the rows; it also
                    // holds the focused row's lift.
                    .padding(panelPadding)
                }
                // tvOS scroll views draw outside their bounds (for focus
                // effects), so a long list would run out of the panel's
                // bottom; it scrolls inside the glass instead.
                .clipped()
                .focusSection()
            }
            .frame(width: Self.width, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(panelShape.fill(.white.opacity(0.06)))
            .glassEffectCompat(.regular, in: panelShape)
            .overlay(panelShape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
            .onChange(of: itemIDs) { _, ids in
                // The focused row went away under focus (an entry turned off
                // or unpaired): hand focus to the selection rather than
                // leaving the engine to pick a row.
                if let focused, !ids.contains(focused) { focusSelection(proxy) }
            }
            .onChange(of: focusRequest) { _, _ in
                focusSelection(proxy)
            }
            .onChange(of: focusHandOffRequest) { _, _ in
                railOwnsFocus = false
                handOffPending = true
                // Focus still here once the pane has had its chance means it
                // stayed on the selected row: the rail owns it again, so moves
                // within it aren't snapped back as entries.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    handOffPending = false
                    if focused != nil, !railOwnsFocus {
                        railOwnsFocus = true
                    }
                }
            }
            .onChange(of: focused) { _, newValue in
                focusDidChange(to: newValue, proxy: proxy)
            }
        }

        private func focusDidChange(to newValue: String?, proxy: ScrollViewProxy) {
            exitCheck?.cancel()
            guard let newValue else {
                handOffPending = false
                // A move onto a row the lazy list only just built passes
                // through nil — for several frames while the list is swiped
                // through fast, so a single turn isn't enough: read as an
                // exit, the next row snapped focus back to the selection.
                // Scrolling fast also hands focus to the scroll view's
                // fast-scroll index, for as long as the user scrubs it; it
                // sits inside the panel, so the verdict waits until focus is
                // outside. Only then has focus left the rail; re-entry takes
                // another press, well after. Pre-arm the mask for it.
                exitCheck = Task { @MainActor in
                    repeat {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, focused == nil else { return }
                    } while systemFocusIsInPanel
                    railOwnsFocus = false
                    onFocusChange(false)
                }
                return
            }
            if !railOwnsFocus {
                onFocusChange(true)
            }
            if !railOwnsFocus, !masksFocus, let selectedID, newValue != selectedID {
                // Entry landed on the wrong row (masked, so it never rendered
                // styled) — snap to the selection. It may sit scrolled out of
                // the lazy list, where a focus write finds nothing: bring it
                // in first (only as far as needed, so a visible selection
                // doesn't move), then focus it a turn later. The mask stays on
                // until focus reaches it — lifted any earlier, the landing row
                // starts its focus fade and flashes. Should the engine refuse
                // the write, it lifts anyway so the rail never stays masked.
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

        /// Whether UIKit's focus sits inside the panel — for a nil `focused`,
        /// on the fast-scroll index, which `@FocusState` can't see.
        private var systemFocusIsInPanel: Bool {
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            guard let window,
                  let item = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                  let space = item.parentFocusEnvironment?.focusItemContainer?.coordinateSpace
            else { return false }
            let frame = space.convert(item.frame, to: window)
            return panelFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }

        /// Focuses the selected row, scrolling it into the lazy list first.
        /// Deferred: a same-frame focus write from a focus or Menu callback
        /// gets dropped.
        private func focusSelection(_ proxy: ScrollViewProxy) {
            guard let selectedID else { return }
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(selectedID)
            }
            Task { @MainActor in focused = selectedID }
        }

        private var rows: some View {
            ForEach(items) { item in
                railButton(item)
            }
        }

        private func railButton(_ item: TVSidebarRailItem) -> some View {
            let isSelected = selectedID == item.id
            // The selected row is exempt: when entry lands there directly, it
            // should read as focused from the first frame.
            let suppressed = masksFocus || (!railOwnsFocus && !isSelected)
            let isItemFocused = (focused == item.id && !suppressed)
                || (handOffPending && isSelected && focused != nil)
            let rowShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            return Button(action: item.action) {
                // Labels start flush at the row's edge; an icon trails, so
                // every label lines up whether or not its row has one.
                HStack(spacing: 16) {
                    // One line at one size: long provider category names
                    // truncate rather than wrap, so every row keeps the same
                    // height.
                    item.title
                        .font(.system(
                            size: 22,
                            weight: isSelected || isItemFocused ? .semibold : .medium
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let icon = item.icon {
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
            .focused($focused, equals: item.id)
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
