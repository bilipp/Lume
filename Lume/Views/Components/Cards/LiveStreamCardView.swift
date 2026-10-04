//
//  LiveStreamCardView.swift
//  Lume
//
//  Card view for displaying a live stream channel
//

import SwiftUI

struct LiveStreamCardView: View {
    let stream: LiveStream
    /// The channel's now/next programmes, resolved once by the parent list (see
    /// `ChannelEPGSnapshot`) rather than by a per-card `@Query`.
    var epg: ChannelEPG?

    private var currentEPG: EPGSlot? {
        epg?.current
    }

    private var nextEPG: EPGSlot? {
        epg?.next
    }

    var body: some View {
        HStack(spacing: 12) {
            // Channel logo
            CachedAsyncImage(url: URL(string: stream.streamIcon ?? ""), maxPixelSize: 60) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            ProgressView()
                        }
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(stream.name)
                    .font(.headline)
                    .lineLimit(1)

                if let current = currentEPG {
                    Text(current.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(current.start, style: .time)
                        Text("-")
                        Text(current.end, style: .time)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if let next = nextEPG {
                        HStack(spacing: 4) {
                            Text("Next:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(next.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(next.start, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if stream.epgChannelId != nil {
                    Text("No EPG data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Live")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if stream.tvArchive > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Catchup: \(stream.tvArchiveDuration)d")
                    }
                    .font(.caption2)
                    .foregroundStyle(.blue)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

#Preview("Basic") {
    LiveStreamCardView(
        stream: LiveStream(
            id: "preview-1",
            streamId: 1,
            name: "BBC One"
        )
    )
    .padding()
}

#Preview("With Archive") {
    LiveStreamCardView(
        stream: LiveStream(
            id: "preview-2",
            streamId: 2,
            name: "CNN International",
            tvArchive: 1,
            tvArchiveDuration: 7
        )
    )
    .padding()
}

#Preview("With Logo") {
    LiveStreamCardView(
        stream: LiveStream(
            id: "preview-3",
            streamId: 3,
            name: "National Geographic",
            streamIcon: "https://example.com/logo.png",
            epgChannelId: "NATGEO",
            tvArchive: 1,
            tvArchiveDuration: 3
        )
    )
    .padding()
}

#Preview("Favorite") {
    let stream = LiveStream(
        id: "preview-4",
        streamId: 4,
        name: "HBO",
        tvArchive: 1,
        tvArchiveDuration: 14
    )
    stream.isFavorite = true
    return LiveStreamCardView(stream: stream)
        .padding()
}
