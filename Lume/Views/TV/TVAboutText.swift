//
//  TVAboutText.swift
//  Lume
//
//  The expandable "About" paragraph for the tvOS movie and series detail
//  screens. Split out from TVDetailComponents so each file stays focused.
//

#if os(tvOS)

    import SwiftUI

    /// The "About" paragraph. tvOS can't hover, so this is a focusable button
    /// that expands the full text inline when selected. The "More" affordance is
    /// only shown when the text actually overflows the collapsed line limit, the
    /// focus state paints a legible dark-on-light card (instead of the default
    /// white-on-white highlight), and selecting it toggles the expansion.
    struct TVAboutText: View {
        let text: String
        var collapsedLineLimit: Int = 4

        @State private var isExpanded = false
        @State private var collapsedHeight: CGFloat = 0
        @State private var fullHeight: CGFloat = 0
        @FocusState private var isFocused: Bool

        /// True once the full text is taller than the collapsed limit allows.
        private var isTruncated: Bool {
            fullHeight > collapsedHeight + 1
        }

        var body: some View {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text)
                        .font(.system(size: 26))
                        .foregroundStyle(isFocused ? .black : .white.opacity(0.85))
                        .lineLimit(isExpanded ? nil : collapsedLineLimit)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(alignment: .topLeading) { truncationProbe }

                    if isTruncated {
                        HStack(spacing: 8) {
                            Text(isExpanded ? "Show Less" : "More")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 22, weight: .semibold))
                        }
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isFocused ? .black : .white)
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.06)))
                )
                .scaleEffect(isFocused ? 1.02 : 1.0)
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.18), value: isFocused)
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .disabled(!isTruncated)
        }

        /// Two hidden copies laid out at the same width as the visible text: one
        /// clamped to the collapsed limit, one unbounded. Comparing their heights
        /// tells us whether the text is actually being cut off.
        private var truncationProbe: some View {
            ZStack(alignment: .topLeading) {
                Text(text)
                    .font(.system(size: 26))
                    .lineLimit(collapsedLineLimit)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: CollapsedHeightKey.self, value: geo.size.height)
                        }
                    )

                Text(text)
                    .font(.system(size: 26))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: FullHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .hidden()
            .onPreferenceChange(CollapsedHeightKey.self) { collapsedHeight = $0 }
            .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
        }
    }

    private struct CollapsedHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private struct FullHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

#endif
