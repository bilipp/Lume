//
//  ContinueWatchingWidget.swift
//  LumeWidgets
//
//  Resume in-progress movies and episodes straight from the Home Screen /
//  Desktop. Every tile deep-links into playback via `lume://play/...`.
//

import SwiftUI
import WidgetKit

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text("Continue Watching", comment: "Widget name"))
        .description(Text("Pick up where you left off.", comment: "Widget description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ContinueWatchingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MediaEntry

    var body: some View {
        if entry.items.isEmpty {
            WidgetEmptyView(symbol: "play.circle", message: "Nothing in progress. Open Lume and start watching.")
        } else {
            switch family {
            case .systemSmall:
                if let item = entry.items.first {
                    smallCard(item)
                        .widgetURL(item.deepLink)
                }
            case .systemLarge:
                rowList(maxRows: 4)
            default:
                posterRow(maxItems: 3)
            }
        }
    }

    private func smallCard(_ item: WidgetMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(image: entry.images[item.imageURL], kind: item.kind)
            if let progress = item.progress {
                ResumeBar(progress: progress)
            }
            Text(item.title)
                .font(.caption.bold())
                .lineLimit(1)
        }
    }

    private func posterRow(maxItems: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(entry.items.prefix(maxItems)) { item in
                Link(destination: item.deepLink) {
                    VStack(alignment: .leading, spacing: 4) {
                        ArtworkView(image: entry.images[item.imageURL], kind: item.kind)
                            .aspectRatio(2 / 3, contentMode: .fit)
                        if let progress = item.progress {
                            ResumeBar(progress: progress)
                        }
                        Text(item.title)
                            .font(.caption2.bold())
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func rowList(maxRows: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entry.items.prefix(maxRows)) { item in
                Link(destination: item.deepLink) {
                    HStack(spacing: 10) {
                        ArtworkView(image: entry.images[item.imageURL], kind: item.kind, cornerRadius: 6)
                            .frame(width: 42, height: 63)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.footnote.bold())
                                .lineLimit(1)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let progress = item.progress {
                                ResumeBar(progress: progress)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
