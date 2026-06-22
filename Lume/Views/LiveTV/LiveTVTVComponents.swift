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
        let onPlay: (LiveStream) -> Void
        @Environment(\.modelContext) private var modelContext
        @Query private var streams: [LiveStream]
        /// Now/next EPG for the visible channels, resolved in one off-main fetch
        /// (see `ChannelEPGSnapshot`) instead of a per-row `@Query`.
        @State private var epgByChannel: [String: ChannelEPG] = [:]
        /// Observed so the EPG lookup refreshes when a guide import finishes.
        @State private var epgSync = EPGSyncService.shared
        /// How many channels are currently rendered. Grows by a page as the list
        /// nears its end so a large category loads lazily instead of all at once.
        @State private var visibleCount = LiveChannelQuery.pageSize

        init(scope: LiveChannelScope, playlistPrefix: String, sort: ContentSortOption, onPlay: @escaping (LiveStream) -> Void) {
            self.scope = scope
            self.playlistPrefix = playlistPrefix
            self.onPlay = onPlay
            _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))
        }

        private var scopedStreams: [LiveStream] {
            LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix)
        }

        var body: some View {
            let channels = scopedStreams
            let visible = Array(channels.prefix(visibleCount))
            ScrollView {
                LazyVStack(spacing: 14) {
                    if channels.isEmpty {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("This category has no channels")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(visible) { stream in
                            TVChannelRow(
                                stream: stream,
                                epg: epgByChannel[stream.epgChannelId ?? ""],
                                onRemove: scope == .recentlyWatched ? { removeFromRecentlyWatched(stream) } : nil
                            ) {
                                onPlay(stream)
                            }
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
    }

    private struct TVChannelRow: View {
        let stream: LiveStream
        /// The channel's now/next programmes, resolved once by the parent list
        /// (see `ChannelEPGSnapshot`) rather than by a per-row `@Query`.
        var epg: ChannelEPG?
        var onRemove: (() -> Void)?
        let onPlay: () -> Void

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
            .recentlyWatchedRemoveMenu(onRemove)
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

    /// The unified tvOS Live TV screen for both layouts: a slim, always-visible
    /// category rail on the leading edge — topped by a single List/Guide switch —
    /// beside the content area, which shows either the channel list or the
    /// programme guide. One rail and one switch, in one place and one style,
    /// across both modes makes moving between the two views consistent.
    struct TVLiveTVScreen: View {
        let sections: [LiveTVSection]
        @Binding var selectedSection: LiveTVSection?
        let displayedSection: LiveTVSection?
        @Binding var layoutModeRaw: String
        let contentSort: ContentSortOption
        let onPlay: (LiveStream) -> Void

        /// The active playlist's id prefix, needed to scope the virtual
        /// (favorites / recently watched) collections in-memory.
        let playlistPrefix: String

        private var layoutMode: LiveTVLayoutMode {
            LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
        }

        var body: some View {
            HStack(spacing: 0) {
                // The rail owns its own focus state. Keeping it in a child means
                // moving focus between categories re-evaluates only the rail —
                // not this screen's `content`, which would otherwise reconstruct
                // `EPGGuideView` (and re-run its grid build) on every keypress.
                TVCategoryRail(
                    sections: sections,
                    selectedSection: $selectedSection,
                    layoutModeRaw: $layoutModeRaw
                )
                content
            }
        }

        @ViewBuilder
        private var content: some View {
            if let section = displayedSection {
                switch layoutMode {
                case .guide:
                    EPGGuideView(scope: section.scope, playlistPrefix: playlistPrefix, sort: contentSort, onPlay: onPlay)
                        .id("\(section.id)-\(contentSort.rawValue)-guide")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .list:
                    TVChannelsList(scope: section.scope, playlistPrefix: playlistPrefix, sort: contentSort, onPlay: onPlay)
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

    // MARK: - tvOS category rail

    /// The leading rail: the List/Guide switch above the scrollable category
    /// list. Owns the rail's `@FocusState` so focus changes here never propagate
    /// up to `TVLiveTVScreen` and rebuild the (expensive) content area.
    private struct TVCategoryRail: View {
        let sections: [LiveTVSection]
        @Binding var selectedSection: LiveTVSection?
        @Binding var layoutModeRaw: String

        /// Which rail control currently holds focus — drives the highlight.
        private enum RailItem: Hashable {
            case mode(String)
            case category(String)
        }

        @FocusState private var focused: RailItem?

        private let railWidth: CGFloat = 280

        private var layoutMode: LiveTVLayoutMode {
            LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                // The switch and the category list are each their own focus
                // section so a Down press moves between them as vertical groups.
                // Without this, pressing Down from the right-hand "Guide" segment
                // misses the left-aligned categories (only the left "List"
                // segment sits directly above them).
                viewModeSwitch
                    .padding(.horizontal, 14)
                    .padding(.top, 40)
                    .padding(.bottom, 18)
                    .focusSection()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sections) { section in
                            categoryButton(section)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            .frame(width: railWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // MARK: View-mode switch

        /// A two-segment List/Guide control rendered as a focusable pill pair —
        /// the system white-fill focus idiom reads clearly with a remote, where a
        /// `.segmented` Picker does not.
        private var viewModeSwitch: some View {
            HStack(spacing: 6) {
                ForEach(LiveTVLayoutMode.allCases) { mode in
                    modeSegment(mode)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
        }

        private func modeSegment(_ mode: LiveTVLayoutMode) -> some View {
            let isActive = layoutMode == mode
            let isItemFocused = focused == .mode(mode.rawValue)
            return Button {
                layoutModeRaw = mode.rawValue
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                    Text(mode.label)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(segmentForeground(isFocused: isItemFocused, isActive: isActive))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(segmentFill(isFocused: isItemFocused, isActive: isActive))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($focused, equals: .mode(mode.rawValue))
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private func segmentForeground(isFocused: Bool, isActive: Bool) -> Color {
            if isFocused { return .black }
            if isActive { return .white }
            return .white.opacity(0.5)
        }

        private func segmentFill(isFocused: Bool, isActive: Bool) -> AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            if isActive { return AnyShapeStyle(.white.opacity(0.22)) }
            return AnyShapeStyle(.clear)
        }

        private func categoryButton(_ section: LiveTVSection) -> some View {
            let isSelected = selectedSection?.id == section.id
            let isItemFocused = focused == .category(section.id)
            return Button {
                selectedSection = section
            } label: {
                HStack(spacing: 8) {
                    if let icon = section.icon {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                    }
                    section.titleText
                        .font(.system(
                            size: 22,
                            weight: isSelected || isItemFocused ? .semibold : .regular
                        ))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(textColor(isFocused: isItemFocused, isSelected: isSelected))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(categoryFill(isFocused: isItemFocused, isSelected: isSelected))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($focused, equals: .category(section.id))
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private func textColor(isFocused: Bool, isSelected: Bool) -> Color {
            if isFocused { return .black }
            if isSelected { return .white }
            return .white.opacity(0.6)
        }

        private func categoryFill(isFocused: Bool, isSelected: Bool) -> AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            if isSelected { return AnyShapeStyle(.white.opacity(0.14)) }
            return AnyShapeStyle(.clear)
        }
    }
#endif
