//
//  ExpandableText.swift
//  Lume
//
//  The expandable synopsis used on the movie and series detail screens. Split
//  out from MediaDetailComponents so each file stays focused.
//

import SwiftUI

/// A synopsis that collapses to a few lines with a "more" affordance. The toggle
/// is only shown when the text genuinely overflows the collapsed line limit —
/// measured from the rendered layout rather than guessed from a character count.
struct ExpandableText: View {
    let text: String
    var collapsedLineLimit: Int = 3

    @State private var isExpanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// True once the full text is actually taller than the collapsed line limit
    /// allows. A character-count heuristic is unreliable — a 200-character
    /// synopsis can still fit within three lines on a wide layout — so we
    /// measure the rendered text instead and only offer the toggle when it
    /// genuinely overflows.
    private var isExpandable: Bool {
        fullHeight > collapsedHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { truncationProbe }
                .animation(.easeInOut(duration: 0.2), value: isExpanded)

            if isExpandable {
                Button(LocalizedStringKey(isExpanded ? "less" : "more")) {
                    isExpanded.toggle()
                }
                .font(.callout.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }

    /// Two hidden copies laid out at the visible text's width: one clamped to the
    /// collapsed limit, one unbounded. Comparing their heights tells us whether
    /// the text is actually being cut off.
    private var truncationProbe: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(.callout)
                .lineLimit(collapsedLineLimit)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: CollapsedTextHeightKey.self, value: geo.size.height)
                    }
                )

            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FullTextHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .hidden()
        .onPreferenceChange(CollapsedTextHeightKey.self) { collapsedHeight = $0 }
        .onPreferenceChange(FullTextHeightKey.self) { fullHeight = $0 }
    }
}

private struct CollapsedTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FullTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview("ExpandableText - Short") {
    ExpandableText(text: "A short synopsis that doesn't need a more/less toggle.")
        .padding()
}

#Preview("ExpandableText - Long") {
    ExpandableText(
        text: "This is a very long synopsis that will definitely need a more/less toggle to expand or collapse "
            + "because it exceeds the character limit we've set. The quick brown fox jumps over the lazy dog. "
            + "This text keeps going and going until it crosses the threshold where the toggle becomes useful "
            + "for the user to read the full content without taking up too much space initially."
    )
    .padding()
}
