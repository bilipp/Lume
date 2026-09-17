//
//  FavoritesWidget.swift
//  LumeWidgets
//
//  Quick-launch tiles for favorite channels and titles, in the user's unified
//  favorites order. Channels and movies deep-link straight into playback;
//  series open their detail screen.
//

import SwiftUI
import WidgetKit

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Favorites", provider: FavoritesProvider()) { entry in
            FavoritesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text("Favorites", comment: "Widget name"))
        .description(Text("Jump straight into your favorite titles and channels.", comment: "Widget description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FavoritesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MediaEntry

    var body: some View {
        if entry.items.isEmpty {
            WidgetEmptyView(symbol: "star", message: "No favorites yet. Mark titles and channels as favorites in Lume.")
        } else {
            switch family {
            case .systemSmall:
                if let item = entry.items.first {
                    tile(item)
                        .widgetURL(item.deepLink)
                }
            case .systemLarge:
                grid(rows: 2, columns: 4)
            default:
                grid(rows: 1, columns: 4)
            }
        }
    }

    private func tile(_ item: WidgetMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork(item)
            Text(item.title)
                .font(.caption.bold())
                .lineLimit(1)
        }
    }

    private func grid(rows: Int, columns: Int) -> some View {
        VStack(spacing: 12) {
            ForEach(0 ..< rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(entry.items.dropFirst(row * columns).prefix(columns)) { item in
                        Link(destination: item.deepLink) {
                            VStack(spacing: 4) {
                                artwork(item)
                                Text(item.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    // Keep an incomplete last row left-aligned with even cells.
                    ForEach(0 ..< missingCells(row: row, columns: columns), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func missingCells(row: Int, columns: Int) -> Int {
        let shown = entry.items.dropFirst(row * columns).prefix(columns).count
        return columns - shown
    }

    @ViewBuilder
    private func artwork(_ item: WidgetMediaItem) -> some View {
        if item.kind == .live {
            ChannelLogoView(image: entry.images[item.imageURL])
                .aspectRatio(1, contentMode: .fit)
        } else {
            ArtworkView(image: entry.images[item.imageURL], kind: item.kind)
                .aspectRatio(2 / 3, contentMode: .fit)
        }
    }
}
