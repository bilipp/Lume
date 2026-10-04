//
//  LiveTVTVComponents.swift
//  Lume
//
//  tvOS-only Live TV browsing components: the wide category rail and the large,
//  focusable channel list with inline now/next EPG. Split out from LiveTVView
//  to keep that file focused on cross-platform composition.
//

#if os(tvOS)
    import SwiftData
    import SwiftUI

    // MARK: - tvOS Channels List

    struct TVChannelsList: View {
        let scope: LiveChannelScope
        let playlistPrefix: String
        /// The active playlist's source, so an empty list can say *why* it is
        /// empty rather than tell a WebDAV user to sync again.
        let sourceType: PlaylistSourceType?
        /// Seeds Multi-View with this channel, gated on Lume Pro by the host.
        let onStartMultiView: (LiveStream) -> Void
        let onPlay: (LiveStream) -> Void
        @Environment(\.modelContext) private var modelContext
        /// Drops channels in categories locked away from a child profile — the
        /// iOS list has always done this; this one didn't, so Favorites and
        /// Recently Watched still surfaced them here.
        @Environment(\.contentRestriction) private var restriction
        @Query private var streams: [LiveStream]
        /// Now/next EPG for the visible channels, resolved in one off-main fetch
        /// (see `ChannelEPGSnapshot`) instead of a per-row `@Query`.
        @State private var epgByChannel: [String: ChannelEPG] = [:]
        /// Observed so the EPG lookup refreshes when a guide import finishes.
        @State private var epgSync = EPGSyncService.shared
        /// How many channels are currently rendered. Grows by a page as the list
        /// nears its end so a large category loads lazily instead of all at once.
        @State private var visibleCount = LiveChannelQuery.pageSize
        /// Drives the "Clear Recently Watched" confirmation alert.
        @State private var confirmingClear = false

        init(
            scope: LiveChannelScope,
            playlistPrefix: String,
            sort: ContentSortOption,
            sourceType: PlaylistSourceType?,
            onStartMultiView: @escaping (LiveStream) -> Void,
            onPlay: @escaping (LiveStream) -> Void
        ) {
            self.scope = scope
            self.playlistPrefix = playlistPrefix
            self.sourceType = sourceType
            self.onStartMultiView = onStartMultiView
            self.onPlay = onPlay
            _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))
        }

        private var scopedStreams: [LiveStream] {
            LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix, restriction: restriction)
        }

        var body: some View {
            let channels = scopedStreams
            let visible = Array(channels.prefix(visibleCount))
            ScrollView {
                LazyVStack(spacing: 14) {
                    if channels.isEmpty {
                        if sourceType.map({ !$0.canCarryLiveChannels }) == true {
                            LiveTVEmptyState(sourceType: sourceType)
                                .padding(.top, 80)
                        } else {
                            ContentUnavailableView(
                                "No Channels",
                                systemImage: "antenna.radiowaves.left.and.right",
                                description: Text("This category has no channels")
                            )
                            .padding(.top, 80)
                        }
                    } else {
                        if scope == .recentlyWatched {
                            clearButton
                        }
                        ForEach(visible) { stream in
                            TVChannelRow(
                                stream: stream,
                                epg: epgByChannel[stream.epgChannelId ?? ""],
                                onRemove: scope == .recentlyWatched ? { removeFromRecentlyWatched(stream) } : nil,
                                onStartMultiView: { onStartMultiView(stream) },
                                onPlay: { onPlay(stream) }
                            )
                            .onAppear {
                                if stream.id == visible.last?.id, visibleCount < channels.count {
                                    visibleCount = min(visibleCount + LiveChannelQuery.pageSize, channels.count)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
            .focusSection()
            // Reload when the visible window or channel set changes, or a guide
            // import settles — EPG is resolved only for the channels on screen.
            .task(id: "\(channels.count)-\(visible.count)-\(epgSync.isSyncing)") {
                await loadEPG(for: visible)
            }
            .alert("Clear Recently Watched", isPresented: $confirmingClear) {
                Button("Clear", role: .destructive) { clearRecentlyWatched() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the list of channels you've recently watched. Your favorites and the channels themselves aren't affected.")
            }
        }

        /// A full-width focusable "Clear" pill pinned above the Recently Watched
        /// rows. Full-width so the focus engine reliably catches a "down" move
        /// into it from the category rail and out of it into the first channel.
        private var clearButton: some View {
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear Recently Watched", systemImage: "trash")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.02))
        }

        private func loadEPG(for channels: [LiveStream]) async {
            let channelIds = Array(Set(channels.compactMap(\.epgChannelId).filter { !$0.isEmpty }))
            guard !channelIds.isEmpty else {
                epgByChannel = [:]
                return
            }
            let container = modelContext.container
            let now = Date()
            epgByChannel = await Task.detached(priority: .userInitiated) {
                ChannelEPGLoader.load(container: container, channelIds: channelIds, now: now)
            }.value
        }

        /// Clears a channel's watch timestamp so it drops out of the Recently
        /// Watched list. The @Query-backed list updates once the change is saved.
        private func removeFromRecentlyWatched(_ stream: LiveStream) {
            stream.lastWatchedDate = nil
            try? modelContext.save()
        }

        /// Empties the whole Recently Watched list for the active playlist. The
        /// section drops away on its own once the last timestamp clears (its
        /// parent gates it on `hasRecents`).
        private func clearRecentlyWatched() {
            let container = modelContext.container
            Task { await StorageManager.clearRecentlyWatchedChannels(playlistPrefix: playlistPrefix, container: container) }
        }
    }

    private struct TVChannelRow: View {
        let stream: LiveStream
        /// The channel's now/next programmes, resolved once by the parent list
        /// (see `ChannelEPGSnapshot`) rather than by a per-row `@Query`.
        var epg: ChannelEPG?
        var onRemove: (() -> Void)?
        var onStartMultiView: (() -> Void)?
        let onPlay: () -> Void

        @Environment(\.modelContext) private var modelContext
        @FocusState private var isFocused: Bool

        private var currentEPG: EPGSlot? {
            epg?.current
        }

        private var nextEPG: EPGSlot? {
            epg?.next
        }

        var body: some View {
            Button(action: onPlay) {
                HStack(spacing: 24) {
                    logo

                    VStack(alignment: .leading, spacing: 6) {
                        Text(stream.name)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)

                        if let current = currentEPG {
                            Text(current.title)
                                .font(.system(size: 25))
                                .foregroundStyle(secondaryColor)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(current.start, style: .time)
                                Text("–")
                                Text(current.end, style: .time)
                            }
                            .font(.system(size: 22))
                            .foregroundStyle(tertiaryColor)

                            if let next = nextEPG {
                                HStack(spacing: 6) {
                                    Text("Next:")
                                    Text(next.title).lineLimit(1)
                                    Text(next.start, style: .time)
                                }
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                            }
                        } else if stream.epgChannelId != nil {
                            Text("No EPG data")
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                        } else {
                            Text("Live")
                                .font(.system(size: 22))
                                .foregroundStyle(secondaryColor)
                        }

                        if stream.tvArchive > 0 {
                            Label("Catchup: \(stream.tvArchiveDuration)d", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.blue)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(tertiaryColor)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.white.opacity(0.06)))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($isFocused)
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .liveChannelMenu(
                stream: stream,
                isFavorite: stream.isFavorite,
                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) },
                onStartMultiView: onStartMultiView,
                onRemoveFromRecents: onRemove
            )
        }

        private var logo: some View {
            CachedAsyncImage(url: URL(string: stream.streamIcon ?? ""), maxPixelSize: 84) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(Color.white.opacity(0.12)).overlay { ProgressView() }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    Rectangle().fill(Color.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(secondaryColor)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var primaryColor: Color {
            .white
        }

        private var secondaryColor: Color {
            .white.opacity(0.7)
        }

        private var tertiaryColor: Color {
            .white.opacity(0.45)
        }
    }

    // MARK: - tvOS Live TV screen

    /// The Live TV screen's horizontal layout, which the guide's two-hour
    /// track width is derived from.
    enum TVLiveTVLayout {
        /// The 1920 pt screen inside tvOS's 80 pt horizontal safe area.
        static let contentWidth: CGFloat = 1760
        static let railWidth: CGFloat = 340
        static let spacing: CGFloat = 32

        /// What the rail leaves for the channel list or guide.
        static var paneWidth: CGFloat {
            contentWidth - railWidth - spacing
        }
    }

    /// The unified tvOS Live TV screen for both layouts: an always-visible
    /// category sidebar on the leading edge beside the content area, which shows
    /// either the channel list or the programme guide. The layout is chosen in
    /// Settings › Player › Live TV.
    struct TVLiveTVScreen: View {
        let sections: [LiveTVSection]
        @Binding var selectedSection: LiveTVSection?
        let displayedSection: LiveTVSection?
        let contentSort: ContentSortOption
        let onPlay: (LiveStream) -> Void
        let onPlayCatchup: (LiveStream, EPGProgramCell) -> Void
        /// Raises Multi-View seeded with a channel, from its long-press menu.
        let onStartMultiView: (LiveStream) -> Void

        /// The active playlist's id prefix, needed to scope the virtual
        /// (favorites / recently watched) collections in-memory.
        let playlistPrefix: String

        /// The active playlist's source, forwarded so an empty channel list can
        /// explain itself. See `LiveTVEmptyState`.
        let sourceType: PlaylistSourceType?

        let layoutMode: LiveTVLayoutMode

        var preview = EPGGuidePreviewInputs()

        /// Bumped when the user activates a rail category, asking the guide to
        /// take focus (landing on the first channel). Reset to 0 once claimed,
        /// so unrelated guide rebuilds (sort changes) never steal focus.
        @State private var guideFocusToken = 0
        @State private var focusRegions = TVLiveTVFocusRegions()
        @State private var recordingStore = RecordingServerStore.shared
        /// The Recordings rail entry is selected; it replaces the channel
        /// list or guide until a category is picked again.
        @State private var showsRecordings = false
        @State private var showingRecordingsPaywall = false

        private var recordingsShown: Bool {
            showsRecordings && recordingStore.isPaired && recordingStore.isUnlocked
        }

        var body: some View {
            HStack(spacing: TVLiveTVLayout.spacing) {
                // The rail owns its own focus state. Keeping it in a child means
                // moving focus between categories re-evaluates only the rail —
                // not this screen's `content`, which would otherwise reconstruct
                // `EPGGuideView` (and re-run its grid build) on every keypress.
                TVCategoryRail(
                    sections: sections,
                    selectedSection: $selectedSection,
                    onCategoryActivated: {
                        showsRecordings = false
                        guideFocusToken += 1
                    },
                    recordings: recordingsEntry
                )
                if recordingsShown {
                    TVRecordingsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .environment(focusRegions)
            .paywall(isPresented: $showingRecordingsPaywall, highlight: .recordingServer)
            .overlay(alignment: .top) {
                // The library has no guide to hand caught focus to.
                if layoutMode == .guide, !recordingsShown {
                    TVLiveTVEntryCatcher(regions: focusRegions) { guideFocusToken += 1 }
                }
            }
        }

        private var recordingsEntry: TVCategoryRailRecordingsEntry? {
            guard recordingStore.isPaired else { return nil }
            let isLocked = !recordingStore.isUnlocked
            return TVCategoryRailRecordingsEntry(isSelected: recordingsShown, isLocked: isLocked) {
                if isLocked {
                    showingRecordingsPaywall = true
                } else {
                    showsRecordings = true
                }
            }
        }

        @ViewBuilder
        private var content: some View {
            if let section = displayedSection {
                switch layoutMode {
                case .guide:
                    EPGGuideView(
                        scope: section.scope,
                        playlistPrefix: playlistPrefix,
                        sort: contentSort,
                        onPlay: onPlay,
                        onPlayCatchup: onPlayCatchup,
                        onStartMultiView: onStartMultiView,
                        focusToken: guideFocusToken,
                        onDidClaimFocus: { guideFocusToken = 0 },
                        preview: preview
                    )
                    .id("\(section.id)-\(contentSort.rawValue)-guide")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .list:
                    TVChannelsList(
                        scope: section.scope,
                        playlistPrefix: playlistPrefix,
                        sort: contentSort,
                        sourceType: sourceType,
                        onStartMultiView: onStartMultiView,
                        onPlay: onPlay
                    )
                    .id("\(section.id)-\(contentSort.rawValue)-list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Select a Category",
                    systemImage: "tablecells",
                    description: Text("Choose a category from the list")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
#endif
