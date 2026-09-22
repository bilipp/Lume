//
//  OnNowWidget.swift
//  LumeWidgets
//
//  The current programme on favorite channels, driven by the EPG data in the
//  shared snapshot. Progress bars tick live via `ProgressView(timerInterval:)`;
//  the timeline only reloads at programme boundaries.
//

import SwiftUI
import WidgetKit

struct OnNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OnNow", provider: OnNowProvider()) { entry in
            OnNowView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text("On Now", comment: "Widget name"))
        .description(Text("What's playing on your favorite channels.", comment: "Widget description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OnNowView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OnNowEntry

    var body: some View {
        if entry.channels.isEmpty {
            WidgetEmptyView(symbol: "antenna.radiowaves.left.and.right", message: "No favorite channels. Favorite channels in Lume to see their guide here.")
        } else {
            switch family {
            case .systemSmall:
                if let channel = entry.channels.first {
                    ChannelNowRow(channel: channel, logo: entry.images[channel.logoURL], compact: true)
                        .widgetURL(channel.deepLink)
                }
            case .systemLarge:
                rows(max: 5)
            default:
                rows(max: 2)
            }
        }
    }

    private func rows(max maxRows: Int) -> some View {
        VStack(spacing: 10) {
            ForEach(entry.channels.prefix(maxRows)) { channel in
                Link(destination: channel.deepLink) {
                    ChannelNowRow(channel: channel, logo: entry.images[channel.logoURL], compact: false)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct ChannelNowRow: View {
    let channel: WidgetChannelNow
    let logo: Image?
    let compact: Bool

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                ChannelLogoView(image: logo)
                    .frame(width: 36, height: 36)
                details
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HStack(spacing: 10) {
                ChannelLogoView(image: logo)
                    .frame(width: 36, height: 36)
                details
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(channel.channelName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let title = channel.nowTitle {
                Text(title)
                    .font(.footnote.bold())
                    .lineLimit(1)
            } else {
                Text("No guide data", comment: "Shown when a channel has no EPG information")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let start = channel.nowStart, let end = channel.nowEnd, start <= end {
                ProgressView(timerInterval: start ... end, countsDown: false)
                    .labelsHidden()
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
            }
            if !compact, let next = channel.nextTitle {
                Text("Next: \(next)", comment: "Upcoming programme on a channel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
