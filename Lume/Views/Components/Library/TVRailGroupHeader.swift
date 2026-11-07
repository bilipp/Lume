//
//  TVRailGroupHeader.swift
//  Lume
//
//  A Combined member's name above its categories in a tvOS category rail.
//

#if os(tvOS)
    import SwiftUI

    /// Plain text, so the focus engine steps over it.
    struct TVRailGroupHeader<Trailing: View>: View {
        let title: String
        @ViewBuilder var trailing: Trailing

        var body: some View {
            HStack(spacing: 10) {
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                trailing
                Spacer(minLength: 0)
            }
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    extension TVRailGroupHeader where Trailing == EmptyView {
        init(title: String) {
            self.init(title: title) { EmptyView() }
        }
    }
#endif
