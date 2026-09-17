//
//  EPGGuideView.swift
//  Lume
//
//  A classic "TV guide" grid for a category: a frozen channel column on the
//  left, a frozen time ruler across the top, and programme blocks sized to
//  their duration. A live "now" line tracks the current moment.
//
//  Data (channels + listings) is queried and shaped into rows once, in this
//  parent. Scroll offset lives in the child scroller, so panning the grid never
//  re-runs the row-building work.
//

import SwiftData
import SwiftUI

struct EPGGuideView: View {
    let scope: LiveChannelScope
    let playlistPrefix: String
    let onPlay: (LiveStream) -> Void
    let onPlayCatchup: (LiveStream, EPGProgramCell) -> Void
    /// Seeds Multi-View from a channel's long-press menu in the column.
    let onStartMultiView: (LiveStream) -> Void
    /// tvOS: non-zero asks the guide to take real focus (a rail category was
    /// just activated); `onDidClaimFocus` resets it once claimed.
    let focusToken: Int
    let onDidClaimFocus: () -> Void

    @Environment(\.modelContext) private var modelContext
    /// The guide is a channel list like any other, so it owes the viewer the same
    /// parental filtering. It matters most in the Favorites and Recently Watched
    /// scopes, which span categories: a channel favorited before its category was
    /// locked would otherwise stay reachable — and playable — from the guide.
    @Environment(\.contentRestriction) private var restriction
    @Query private var streams: [LiveStream]

    private let timeline: EPGTimeline

    /// The guide window's programme cells, grouped by channel. Fetched *and*
    /// tiled in one off-main pass scoped to *this category's* channels (see
    /// `EPGGuideLoader` / `EPGGridBuilder.cells`). A view-context
    /// `@Query<EPGListing>` here instead pulled the entire guide window across
    /// every playlist onto the main thread and re-fired on every sync write —
    /// the freeze-on-open and stutter-while-scrolling this fixes; tiling on
    /// main was a further open-freeze on categories with hundreds of channels.
    @State private var cellsByChannel: [String: [EPGProgramCell]] = [:]
    /// Bumped whenever `cellsByChannel` is replaced. The scroller's subtrees
    /// are `Equatable`-gated on it (plus the row count), so remote presses
    /// never re-evaluate the grid — only actual data changes do.
    @State private var dataVersion = 0
    /// Observed so the guide refreshes once a guide import settles.
    @State private var epgSync = EPGSyncService.shared

    init(
        scope: LiveChannelScope,
        playlistPrefix: String,
        sort: ContentSortOption,
        onPlay: @escaping (LiveStream) -> Void,
        onPlayCatchup: @escaping (LiveStream, EPGProgramCell) -> Void = { _, _ in },
        onStartMultiView: @escaping (LiveStream) -> Void = { _ in },
        focusToken: Int = 0,
        onDidClaimFocus: @escaping () -> Void = {}
    ) {
        self.scope = scope
        self.playlistPrefix = playlistPrefix
        self.onPlay = onPlay
        self.onPlayCatchup = onPlayCatchup
        self.onStartMultiView = onStartMultiView
        self.focusToken = focusToken
        self.onDidClaimFocus = onDidClaimFocus

        // A longer reach into the past than the default: aired programmes on
        // archive channels are replayable from here, so the window doubles as a
        // catch-up browser.
        let timeline = EPGTimeline.live(
            now: Date(), pointsPerMinute: EPGMetrics.current.pointsPerMinute, hoursBehind: 12
        )
        self.timeline = timeline

        _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))
    }

    private var scopedStreams: [LiveStream] {
        LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix, restriction: restriction)
    }

    var body: some View {
        let channels = scopedStreams
        Group {
            if channels.isEmpty {
                ContentUnavailableView(
                    "No Channels",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("This category has no channels")
                )
            } else {
                EPGGridScroller(
                    rows: buildRows(for: channels),
                    timeline: timeline,
                    dataVersion: dataVersion,
                    onPlay: onPlay,
                    onPlayCatchup: onPlayCatchup,
                    onStartMultiView: onStartMultiView,
                    focusToken: focusToken,
                    onDidClaimFocus: onDidClaimFocus
                )
            }
        }
        // Reload when the channel set changes or a guide import settles. Keyed on
        // `isSyncing` (which flips twice per sync) rather than observing the store,
        // so the grid rebuilds a handful of times — not on every batch write.
        .task(id: "\(channels.count)-\(epgSync.isSyncing)") {
            await loadListings(for: channels)
        }
    }

    /// Zips each scoped stream with its pre-tiled cells.
    /// Runs only when the streams or loaded cells change — not on scroll.
    private func buildRows(for channels: [LiveStream]) -> [EPGChannelRow] {
        EPGGridBuilder.rows(streams: channels, cellsByChannel: cellsByChannel, timeline: timeline)
    }

    /// Loads the window's listings in two chunks: a few hours around "now"
    /// first, so a large category paints its opening viewport immediately,
    /// then the full window in the background. Each phase fetches *and* tiles
    /// off-main and lands as one `dataVersion` bump.
    private func loadListings(for channels: [LiveStream]) async {
        let channelIds = Array(Set(channels.compactMap(\.epgChannelId).filter { !$0.isEmpty }))
        guard !channelIds.isEmpty else {
            cellsByChannel = [:]
            dataVersion += 1
            return
        }
        let container = modelContext.container
        let timeline = timeline
        let now = Date()

        func loadChunk(from start: Date, to end: Date) async -> [String: [EPGProgramCell]] {
            await Task.detached(priority: .userInitiated) {
                let listings = EPGGuideLoader.load(
                    container: container,
                    channelIds: channelIds,
                    windowStart: start,
                    windowEnd: end
                )
                return listings.mapValues { EPGGridBuilder.cells(for: $0, timeline: timeline) }
            }.value
        }

        let quickStart = max(timeline.start, now.addingTimeInterval(-2 * 3600))
        let quickEnd = min(timeline.end, now.addingTimeInterval(6 * 3600))
        let quick = await loadChunk(from: quickStart, to: quickEnd)
        guard !Task.isCancelled else { return }
        cellsByChannel = quick
        dataVersion += 1

        let full = await loadChunk(from: timeline.start, to: timeline.end)
        guard !Task.isCancelled else { return }
        cellsByChannel = full
        dataVersion += 1
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("EPG Guide") {
        EPGGuidePreviewHarness()
    }

    /// Seeds an in-memory store with channels and listings around "now" so the
    /// grid can be exercised in the canvas without a live playlist.
    private struct EPGGuidePreviewHarness: View {
        private let container: ModelContainer
        private let category: Category

        init() {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            let container = try! ModelContainer(
                for: Playlist.self, Category.self, LiveStream.self, EPGListing.self,
                configurations: config
            )
            let ctx = container.mainContext

            let playlist = Playlist(name: "Preview", serverURL: "http://example.com", username: "u", password: "p")
            ctx.insert(playlist)
            let category = Category(apiId: "20", name: "News", parentId: 0, type: .live, playlist: playlist)
            ctx.insert(category)

            let names = ["BBC One", "CNN International", "HBO", "Sky Sports", "Discovery", "Nat Geo", "ESPN", "ITV"]
            let titles = ["The Evening News", "Morning Show", "Wild Documentary", "Live Football", "Movie Night", "Talk of the Town"]
            let now = Date()
            let windowStart = now.addingTimeInterval(-3600)
            let windowEnd = now.addingTimeInterval(6 * 3600)

            for (index, name) in names.enumerated() {
                let channelId = "chan-\(index)"
                let stream = LiveStream(
                    id: "\(playlist.id.uuidString)-live-\(index)",
                    streamId: 100 + index,
                    name: name,
                    epgChannelId: channelId,
                    tvArchive: index % 3 == 0 ? 1 : 0,
                    tvArchiveDuration: 7,
                    num: index,
                    categoryId: category.id
                )
                ctx.insert(stream)

                var cursor = windowStart.addingTimeInterval(Double(index % 3) * 600) // stagger starts
                var slot = index
                while cursor < windowEnd {
                    let duration = TimeInterval([1800, 2700, 3600][slot % 3])
                    let end = cursor.addingTimeInterval(duration)
                    ctx.insert(EPGListing(
                        id: "\(channelId)-\(slot)",
                        channelId: channelId,
                        title: titles[slot % titles.count],
                        listingDescription: "A sample programme synopsis used for preview purposes only.",
                        start: cursor,
                        end: end
                    ))
                    cursor = end
                    slot += 1
                }
            }
            try? ctx.save()

            self.container = container
            self.category = category
        }

        var body: some View {
            EPGGuideView(scope: .category(category.id), playlistPrefix: "", sort: .playlist) { _ in }
                .modelContainer(container)
                .frame(minHeight: 520)
        }
    }
#endif
