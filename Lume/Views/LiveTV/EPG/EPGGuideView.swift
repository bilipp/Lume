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

    @Query private var streams: [LiveStream]
    @Query private var listings: [EPGListing]

    private let timeline: EPGTimeline

    init(scope: LiveChannelScope, playlistPrefix: String, sort: ContentSortOption, onPlay: @escaping (LiveStream) -> Void) {
        self.scope = scope
        self.playlistPrefix = playlistPrefix
        self.onPlay = onPlay

        let timeline = EPGTimeline.live(now: Date(), pointsPerMinute: EPGMetrics.current.pointsPerMinute)
        self.timeline = timeline

        _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))

        // Fetch only listings overlapping the window, then group in memory.
        let windowStart = timeline.start
        let windowEnd = timeline.end
        _listings = Query(
            filter: #Predicate<EPGListing> { $0.end > windowStart && $0.start < windowEnd },
            sort: [SortDescriptor(\.start)]
        )
    }

    private var scopedStreams: [LiveStream] {
        LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix)
    }

    var body: some View {
        if scopedStreams.isEmpty {
            ContentUnavailableView(
                "No Channels",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("This category has no channels")
            )
        } else {
            EPGGridScroller(rows: buildRows(), timeline: timeline, onPlay: onPlay)
        }
    }

    /// Groups the windowed listings by channel and tiles each stream into a row.
    /// Runs only when the queries change — not on scroll.
    private func buildRows() -> [EPGChannelRow] {
        let grouped = Dictionary(grouping: listings, by: \.channelId)
        return EPGGridBuilder.rows(streams: scopedStreams, listingsByChannel: grouped, timeline: timeline)
    }
}

// MARK: - Selection

/// A tapped programme, carried to the detail sheet.
private struct EPGSelection: Identifiable {
    let id: String
    let stream: LiveStream
    let cell: EPGProgramCell
}

// MARK: - Scroll sync

/// Shared, observable scroll offset. Only the ruler and channel column observe
/// it, so panning the grid updates *their* offset modifiers without re-running
/// the (expensive) programme grid. See `skills/swiftui-performance.md`.
@MainActor
@Observable
final class EPGScrollSync {
    var offset = CGPoint.zero
}

// MARK: - Scroller

/// Lays out the frozen panes (corner, ruler, channel column) beside the single
/// scrollable grid. The same layout serves every platform: touch and pointer
/// drag the grid, tvOS moves it by focus, and the frozen column sits *beside*
/// the grid so a focused programme is never hidden behind it.
private struct EPGGridScroller: View {
    let rows: [EPGChannelRow]
    let timeline: EPGTimeline
    let onPlay: (LiveStream) -> Void

    private let metrics = EPGMetrics.current
    private let now = Date()

    @State private var sync = EPGScrollSync()
    @State private var selection: EPGSelection?
    @State private var jumpToken = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header: corner + time ruler. Touch/pointer get a jump-to-now
            // button in the corner; tvOS auto-scrolls to now on appear and has
            // no use for a corner button it can't easily reach, so the corner
            // is left empty there.
            HStack(spacing: 0) {
                corner
                    .frame(width: metrics.channelColumnWidth, height: metrics.headerHeight)

                EPGRulerStrip(timeline: timeline, metrics: metrics, now: now, sync: sync)
            }
            .frame(height: metrics.headerHeight)

            #if !os(tvOS)
                Divider()
            #endif

            // Body: frozen channel column + scrollable programme grid.
            HStack(spacing: 0) {
                EPGFrozenColumn(rows: rows, metrics: metrics, sync: sync)

                EPGGrid(
                    rows: rows,
                    timeline: timeline,
                    metrics: metrics,
                    now: now,
                    sync: sync,
                    jumpToken: jumpToken,
                    nowTarget: nowScrollTarget,
                    onPlay: { row, _ in onPlay(row.stream) },
                    onShowDetails: { row, cell in
                        selection = EPGSelection(id: cell.id, stream: row.stream, cell: cell)
                    }
                )
            }
        }
        #if !os(tvOS)
        .background(.background)
        #endif
        .sheet(item: $selection) { selection in
            EPGProgramDetailView(
                stream: selection.stream,
                cell: selection.cell,
                now: now,
                onPlay: { onPlay(selection.stream) }
            )
        }
    }

    /// Scroll offset that places "now" just inside the leading edge of the grid.
    private var nowScrollTarget: CGFloat {
        max(0, timeline.x(for: now) - 12)
    }

    @ViewBuilder
    private var corner: some View {
        #if os(tvOS)
            Color.clear
        #else
            Button {
                jumpToken += 1
            } label: {
                Label("Now", systemImage: "smallcircle.filled.circle")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) { Rectangle().fill(.quaternary).frame(width: 1) }
        #endif
    }
}

// MARK: - Ruler strip

/// The time ruler, shifted to mirror the grid's horizontal offset. Observes the
/// shared sync so only its offset updates while scrolling — the ruler's own
/// content is built once.
private struct EPGRulerStrip: View {
    let timeline: EPGTimeline
    let metrics: EPGMetrics
    let now: Date
    let sync: EPGScrollSync

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: metrics.headerHeight)
            .overlay(alignment: .leading) {
                ZStack(alignment: .topLeading) {
                    EPGTimeRuler(timeline: timeline, metrics: metrics)
                    nowPill.offset(x: timeline.x(for: now))
                }
                .frame(width: timeline.totalWidth, alignment: .leading)
                .offset(x: -sync.offset.x)
            }
            .clipped()
    }

    private var nowPill: some View {
        Text("Now")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
            .fixedSize()
            .alignmentGuide(.leading) { $0.width / 2 }
    }
}

// MARK: - Frozen column

/// The channel column, shifted to mirror the grid's vertical offset. Built once;
/// only the offset modifier changes as the grid scrolls.
private struct EPGFrozenColumn: View {
    let rows: [EPGChannelRow]
    let metrics: EPGMetrics
    let sync: EPGScrollSync

    var body: some View {
        Color.clear
            .frame(width: metrics.channelColumnWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                ColumnCells(rows: rows, metrics: metrics)
                    .offset(y: -sync.offset.y)
            }
            .clipped()
        #if !os(tvOS)
            // The channel cards on tvOS already read as a separate rail, so
            // a vertical rule would only add visual weight.
            .overlay(alignment: .trailing) { Rectangle().fill(.quaternary).frame(width: 1) }
        #endif
    }

    private struct ColumnCells: View {
        let rows: [EPGChannelRow]
        let metrics: EPGMetrics

        var body: some View {
            VStack(spacing: metrics.rowSpacing) {
                ForEach(rows) { row in
                    EPGChannelCell(row: row, metrics: metrics)
                }
            }
        }
    }
}

// MARK: - Grid

/// The single scrollable surface. Owns its scroll position (used only for
/// programmatic jump-to-now) and publishes its offset to the shared sync. Its
/// programme rows live in a separate child so the per-frame scroll-position
/// write-back never rebuilds them.
private struct EPGGrid: View {
    let rows: [EPGChannelRow]
    let timeline: EPGTimeline
    let metrics: EPGMetrics
    let now: Date
    let sync: EPGScrollSync
    let jumpToken: Int
    let nowTarget: CGFloat
    let onPlay: (EPGChannelRow, EPGProgramCell) -> Void
    let onShowDetails: (EPGChannelRow, EPGProgramCell) -> Void

    @State private var position = ScrollPosition()
    @State private var didInitialScroll = false
    #if os(tvOS)
        /// tvOS centers scroll content that is shorter than the viewport. The
        /// frozen channel column pins its cells to the top, so without this the
        /// two panes drift apart when a category has only a few channels. Pinning
        /// the rows to at least the viewport height (top-aligned) keeps them level.
        @State private var viewportHeight: CGFloat = 0
    #endif

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            EPGRows(rows: rows, timeline: timeline, metrics: metrics, now: now, onPlay: onPlay, onShowDetails: onShowDetails)
            #if os(tvOS)
                .frame(minHeight: viewportHeight, alignment: .topLeading)
            #endif
        }
        #if os(tvOS)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { viewportHeight = $1 }
            }
        }
        #endif
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, new in
            sync.offset = CGPoint(x: max(0, new.x), y: max(0, new.y))
        }
        #if os(tvOS)
        .focusSection()
        #endif
        .onAppear {
            guard !didInitialScroll else { return }
            didInitialScroll = true
            position.scrollTo(x: nowTarget)
        }
        .onChange(of: jumpToken) {
            withAnimation(.easeInOut(duration: 0.4)) {
                position.scrollTo(x: nowTarget)
            }
        }
    }
}

/// The programme rows plus the now line. Free of any scroll-offset dependency,
/// so it builds once and lazily loads rows as they scroll into view.
private struct EPGRows: View {
    let rows: [EPGChannelRow]
    let timeline: EPGTimeline
    let metrics: EPGMetrics
    let now: Date
    let onPlay: (EPGChannelRow, EPGProgramCell) -> Void
    let onShowDetails: (EPGChannelRow, EPGProgramCell) -> Void

    private var contentHeight: CGFloat {
        guard !rows.isEmpty else { return 0 }
        return CGFloat(rows.count) * metrics.rowHeight + CGFloat(rows.count - 1) * metrics.rowSpacing
    }

    var body: some View {
        LazyVStack(spacing: metrics.rowSpacing) {
            ForEach(rows) { row in
                EPGProgramStrip(
                    row: row,
                    metrics: metrics,
                    now: now,
                    contentWidth: timeline.totalWidth,
                    onPlay: { cell in onPlay(row, cell) },
                    onShowDetails: { cell in onShowDetails(row, cell) }
                )
            }
        }
        .frame(width: timeline.totalWidth, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            TimelineView(.everyMinute) { context in
                EPGNowIndicator(height: contentHeight)
                    .offset(x: timeline.x(for: context.date) - 4.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Programme strip

/// A single channel's row of programme blocks. Programmes are buttons; gaps are
/// inert. A quick click plays the channel; a long press opens the programme
/// detail sheet.
private struct EPGProgramStrip: View {
    let row: EPGChannelRow
    let metrics: EPGMetrics
    let now: Date
    /// The full timeline width. Pinned on the lazy stack so the row reserves its
    /// whole horizontal extent up front — the scroll region and the "now" line
    /// stay correct even before trailing (off-screen) blocks are realized.
    let contentWidth: CGFloat
    let onPlay: (EPGProgramCell) -> Void
    let onShowDetails: (EPGProgramCell) -> Void

    var body: some View {
        // Lazy so only the handful of on-screen programmes per row are built and
        // made focusable. An eager HStack tiles the entire ~25-hour window —
        // hundreds of shadowed, focusable buttons the tvOS focus engine must
        // track every frame, which is what made focus-scrolling stutter.
        LazyHStack(spacing: 0) {
            ForEach(row.cells) { cell in
                if cell.isGap {
                    EPGProgramBlockView(cell: cell, metrics: metrics, now: now, isFocused: false)
                } else {
                    Button {
                        onPlay(cell)
                    } label: {
                        Color.clear.frame(width: cell.width, height: metrics.rowHeight)
                    }
                    .buttonStyle(EPGBlockButtonStyle(cell: cell, metrics: metrics, now: now))
                    // Long press (press-and-hold Select on tvOS) opens the detail
                    // sheet. The gesture takes the press once it recognizes, so a
                    // hold doesn't also fire the button's play action.
                    .onLongPressGesture(minimumDuration: 0.4) {
                        onShowDetails(cell)
                    }
                    .accessibilityLabel(Text(cell.title))
                    .accessibilityHint(Text("\(cell.start, format: .dateTime.hour().minute()) to \(cell.end, format: .dateTime.hour().minute()) on \(row.name)"))
                    .accessibilityAction(named: Text("Show Details")) { onShowDetails(cell) }
                }
            }
        }
        .frame(width: contentWidth, height: metrics.rowHeight, alignment: .leading)
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
