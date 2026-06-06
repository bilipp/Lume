//
//  TVReorderableContentList.swift
//  Lume
//
//  A focus-driven reorderable list for the tvOS Content Management surfaces
//  (categories and the channels within a category). It replaces the old
//  position-by-position up/down buttons, which stamped `customOrder` on every
//  item — and therefore wrote to SwiftData, invalidated the `@Query`, re-sorted
//  the store and rebuilt the whole list — on *every single keypress*. With many
//  items that cost seconds per step, and moving an item from bottom to top meant
//  dozens of those steps.
//
//  Instead this uses a pick-up / place gesture:
//
//    1. Select a row to LIFT it. A local working copy of the order is seeded;
//       nothing is persisted.
//    2. Up/down slide the lifted row through that *local* copy via
//       `onMoveCommand`. Every other control is disabled while a row is lifted,
//       so the remote's up/down move the item rather than focus, and focus stays
//       pinned to the lifted row (tvOS keeps the focused view on screen for us).
//    3. Select again to DROP — committing the whole arrangement in a single
//       batched `customOrder` stamp. Menu cancels and restores the original.
//
//  The net effect: one persistence pass per move, regardless of distance, and no
//  `@Query`/re-sort/rebuild churn while the user is positioning the item.
//

#if os(tvOS)

    import SwiftUI

    struct TVReorderableContentList<Item: ContentItem>: View {
        /// The persisted order (already sorted by the caller). Shown whenever no
        /// row is lifted.
        let items: [Item]
        let title: (Item) -> String
        let isHidden: (Item) -> Bool
        /// When non-nil, each row shows a trailing drill-in link to the returned
        /// category's channels. nil for the channel list itself.
        var drillValue: ((Item) -> Category)?
        let onToggleHidden: (Item) -> Void
        /// Commit the final arrangement (single batched persistence pass).
        let onCommitOrder: ([Item]) -> Void
        /// Lets the host disable its type picker / Reset while a row is lifted,
        /// so they can't steal focus mid-move.
        @Binding var isReordering: Bool
        /// Proxy for the host's enclosing `ScrollView`. tvOS only auto-scrolls
        /// when focus *moves* between views; while a row is lifted it keeps focus
        /// and merely changes position, so we scroll it back into view ourselves
        /// after each step.
        let scrollProxy: ScrollViewProxy

        /// The local working order while a row is lifted; nil when at rest. Held
        /// in `@State` so sliding the lifted row never touches SwiftData.
        @State private var working: [Item]?
        @State private var liftedID: String?
        @FocusState private var focusedID: String?

        init(
            items: [Item],
            title: @escaping (Item) -> String,
            isHidden: @escaping (Item) -> Bool,
            drillValue: ((Item) -> Category)? = nil,
            onToggleHidden: @escaping (Item) -> Void,
            onCommitOrder: @escaping ([Item]) -> Void,
            isReordering: Binding<Bool>,
            scrollProxy: ScrollViewProxy
        ) {
            self.items = items
            self.title = title
            self.isHidden = isHidden
            self.drillValue = drillValue
            self.onToggleHidden = onToggleHidden
            self.onCommitOrder = onCommitOrder
            _isReordering = isReordering
            self.scrollProxy = scrollProxy
        }

        private var displayed: [Item] {
            working ?? items
        }

        private var orderKey: [String] {
            displayed.map(\.id)
        }

        var body: some View {
            VStack(spacing: 6) {
                // Invisible focus sinks bracketing the rows, present only during a
                // move. An up/down press off the lifted row lands on one of these
                // — far nearer than the tab bar above the screen — so the escape
                // never leaves the list and there's no visible flash before the
                // lock (below) returns focus.
                if liftedID != nil { focusBarrier }

                ForEach(displayed, id: \.id) { item in
                    let lifted = liftedID == item.id
                    TVReorderRow(
                        id: item.id,
                        title: title(item),
                        isHidden: isHidden(item),
                        isLifted: lifted,
                        isMoving: liftedID != nil,
                        drillValue: drillValue?(item),
                        focus: $focusedID,
                        onGrabOrDrop: { lifted ? drop() : lift(item) },
                        onToggleHidden: { onToggleHidden(item) },
                        onMove: handleMove,
                        onCancel: cancel
                    )
                    .id(item.id)
                }

                if liftedID != nil { focusBarrier }
            }
            .focusSection()
            .animation(.easeOut(duration: 0.2), value: orderKey)
            // Focus lock: every non-lifted row is disabled during a move, so if
            // focus ever leaves the lifted row (onto a barrier above, or anywhere
            // else), bounce it straight back so it stays pinned to the row being
            // placed and keeps receiving the move commands.
            .onChange(of: focusedID) { _, newValue in
                guard let liftedID, newValue != liftedID else { return }
                focusedID = liftedID
            }
        }

        /// A zero-height, fully transparent focusable strip. With its focus effect
        /// disabled it never draws anything, so catching a stray focus move here is
        /// invisible — unlike the tab bar lighting up.
        private var focusBarrier: some View {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .focusable()
                .focusEffectDisabled()
        }

        // MARK: - Pick up / place

        private func lift(_ item: Item) {
            working = items
            liftedID = item.id
            focusedID = item.id
            isReordering = true
            scrollLiftedIntoView()
        }

        private func drop() {
            if let working { onCommitOrder(working) }
            endMove()
        }

        private func cancel() {
            endMove()
        }

        private func endMove() {
            let keep = liftedID
            working = nil
            liftedID = nil
            isReordering = false
            // Keep focus on the row the user was just holding.
            focusedID = keep
        }

        private func handleMove(_ direction: MoveCommandDirection) {
            guard var order = working,
                  let liftedID,
                  let from = order.firstIndex(where: { $0.id == liftedID })
            else { return }

            let target: Int
            switch direction {
            case .up: target = from - 1
            case .down: target = from + 1
            default: return
            }
            guard order.indices.contains(target) else { return }

            order.swapAt(from, target)
            working = order
            scrollLiftedIntoView()
        }

        /// Keep the lifted row centred so the user can always see where it's
        /// going — `.center` works equally well moving up or down, and SwiftUI
        /// clamps it at the ends.
        private func scrollLiftedIntoView() {
            guard let liftedID else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollProxy.scrollTo(liftedID, anchor: .center)
            }
        }
    }

    // MARK: - Row

    /// One row of `TVReorderableContentList`. The leading area is a single
    /// focusable "grab" control spanning the row; selecting it lifts the row (or
    /// drops it when already lifted). The trailing hide / channels controls only
    /// exist at rest — while any row is lifted they're gone and every non-lifted
    /// row is disabled, which is what traps the remote's up/down on the lifted
    /// row so `onMoveCommand` can reorder instead of focus moving away.
    private struct TVReorderRow: View {
        let id: String
        let title: String
        let isHidden: Bool
        let isLifted: Bool
        let isMoving: Bool
        let drillValue: Category?
        var focus: FocusState<String?>.Binding
        let onGrabOrDrop: () -> Void
        let onToggleHidden: () -> Void
        let onMove: (MoveCommandDirection) -> Void
        let onCancel: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                Button(action: onGrabOrDrop) {
                    HStack(spacing: 14) {
                        Image(systemName: isLifted ? "arrow.up.and.down" : "line.3.horizontal")
                            .font(.system(size: 22, weight: .semibold))
                        Text(title)
                            .font(.system(size: TVSettingsMetrics.rowFontSize))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(TVReorderRowButtonStyle(isLifted: isLifted, dimmed: isHidden))
                .focused(focus, equals: id)
                // Only attach the handlers while lifted: passing nil keeps normal
                // focus traversal / Menu behaviour when at rest.
                .onMoveCommand(perform: isLifted ? { onMove($0) } : nil)
                .onExitCommand(perform: isLifted ? onCancel : nil)
                .accessibilityLabel(isLifted ? "Placing \(title). Move up or down, then select to place." : "Move \(title)")

                if !isMoving {
                    Button(action: onToggleHidden) {
                        Image(systemName: isHidden ? "eye.slash" : "eye")
                    }
                    .buttonStyle(TVContentIconButtonStyle())
                    .accessibilityLabel(isHidden ? "Show \(title)" : "Hide \(title)")

                    if let drillValue {
                        NavigationLink(value: drillValue) {
                            HStack(spacing: 10) {
                                Text("Channels")
                                Image(systemName: "chevron.right")
                            }
                        }
                        .buttonStyle(TVContentActionButtonStyle())
                    }
                }
            }
            // Non-lifted rows step aside (dimmed, non-focusable) during a move.
            .disabled(isMoving && !isLifted)
            .opacity(isMoving && !isLifted ? 0.35 : 1)
            .animation(.easeOut(duration: 0.18), value: isMoving)
        }
    }

    // MARK: - Button styles

    /// The full-width grab/drop control. At rest it matches the other tvOS
    /// settings rows (faint fill, light highlight on focus); when lifted it reads
    /// as "picked up" — solid fill, white border, a touch of scale and shadow.
    struct TVReorderRowButtonStyle: ButtonStyle {
        let isLifted: Bool
        let dimmed: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isLifted: isLifted, dimmed: dimmed)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isLifted: Bool
            let dimmed: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let highlighted = isLifted || isFocused
                let fill: AnyShapeStyle = highlighted
                    ? AnyShapeStyle(Color.white.opacity(0.95))
                    : AnyShapeStyle(Color.white.opacity(0.05))
                let foreground: Color = highlighted ? .black : (dimmed ? .secondary : .white)

                return configuration.label
                    .foregroundStyle(foreground)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, TVSettingsMetrics.rowVPadding + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(fill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(isLifted ? 0.9 : 0), lineWidth: 3)
                    )
                    .scaleEffect(isLifted ? 1.02 : 1)
                    .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: isLifted ? 16 : 0, y: isLifted ? 10 : 0)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
                    .animation(.easeOut(duration: 0.18), value: isLifted)
            }
        }
    }

    /// Compact square icon button used for the per-row hide toggle.
    struct TVContentIconButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .opacity(isEnabled ? 1 : 0.25)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isFocused ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(Color.white.opacity(0.08)))
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

    /// Pill action button (e.g. "Channels") for tvOS rows.
    struct TVContentActionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isFocused ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(Color.white.opacity(0.08)))
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

#endif
