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

                if PlayableMedia.isCatchupCapable(stream: stream) {
                    CatchupBadge(days: PlayableMedia.archiveBadgeDays(for: stream))
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

#Preview("M3U Catch-up") {
    let flussonic = LiveStream(
        id: "preview-5",
        streamId: 5,
        name: "Sky News (m3u)",
        tvArchive: 1,
        tvArchiveDuration: 3,
        catchupTypeRaw: CatchupType.flussonic.rawValue
    )
    flussonic.directURL = "http://example.com:8080/skynews/video.m3u8"

    // Declared catch-up, depth unknown: the badge is glyph-only.
    let unknownDepth = LiveStream(
        id: "preview-6",
        streamId: 6,
        name: "Euronews (m3u)",
        tvArchive: 1,
        tvArchiveDuration: 0,
        catchupTypeRaw: CatchupType.default.rawValue,
        catchupSource: "http://example.com:8080/live/euronews.m3u8?utc={utc}"
    )
    unknownDepth.directURL = "http://example.com:8080/live/euronews.m3u8"

    // An m3u channel flagged as having an archive but carrying no dialect —
    // what a row left over from before the import learned `catchupTypeRaw`
    // looks like. The capability gate reads the dialect, not the flag, so this
    // gets no affordance at all.
    let unbuildable = LiveStream(
        id: "preview-7",
        streamId: 7,
        name: "Local News (m3u, no archive)",
        tvArchive: 1,
        tvArchiveDuration: 5
    )
    unbuildable.directURL = "http://example.com:8080/local/index.m3u8"

    return VStack(alignment: .leading) {
        LiveStreamCardView(stream: flussonic)
        LiveStreamCardView(stream: unknownDepth)
        LiveStreamCardView(stream: unbuildable)
    }
    .padding()
}
