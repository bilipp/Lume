//
//  WhatsNewItemRow.swift
//  Lume
//
//  One highlight: a tinted symbol tile, the title and a one-line summary. Used
//  by the sheet and the release history.
//

import SwiftUI

struct WhatsNewItemRow: View {
    let item: WhatsNewItem

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing) {
            Image(systemName: item.symbol)
                .font(Metrics.symbolFont)
                .foregroundStyle(.tint)
                .frame(width: Metrics.tile, height: Metrics.tile)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: Metrics.tile * 0.24, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                    if item.isPro {
                        PremiumBadge()
                    }
                }
                Text(item.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private enum Metrics {
        #if os(tvOS)
            static let tile: CGFloat = 72
            static let spacing: CGFloat = 28
            static let symbolFont = Font.system(size: 32, weight: .medium)
        #else
            static let tile: CGFloat = 44
            static let spacing: CGFloat = 16
            static let symbolFont = Font.title3.weight(.medium)
        #endif
    }
}
