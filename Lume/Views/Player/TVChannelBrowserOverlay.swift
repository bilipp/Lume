//
//  TVChannelBrowserOverlay.swift
//  Lume
//
//  The in-player channel browser for live TV on tvOS, raised by a left press
//  on the Siri remote while watching with the controls hidden. Two Liquid
//  Glass columns slide in over the leading edge: the category rail (the same
//  sections the Live TV screen shows — Favorites / Recently Watched / synced
//  categories) and the channels of the focused category. The playing channel's
//  category and the channel itself are pre-selected; moving focus across
//  categories loads their channels in place, and selecting a channel switches
//  the stream without leaving the player.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVChannelBrowserOverlay: View {
        /// The live stream currently playing.
        let media: PlayableMedia
        /// Switch playback to the picked channel. The host closes the browser.
        let onSelect: (PlayableMedia) -> Void
        /// Close without switching (Menu press, or re-picking the current channel).
        let onClose: () -> Void

        @Environment(\.modelContext) private var modelContext
        /// The same sort choices the Live TV browse screen uses, so the browser
        /// mirrors the order the viewer knows from the channel list.
        @AppStorage(SortStorageKey.liveCategories)
        private var categorySortRaw: String = CategorySortOption.playlist.rawValue
        @AppStorage(SortStorageKey.liveContent)
        private var contentSortRaw: String = ContentSortOption.playlist.rawValue

        @State private var sections: [LiveTVSection] = []
        /// The section whose channels fill the right column.
        @State private var selectedSectionID: String?
        @State private var channels: [LiveStream] = []
        /// Programme titles airing now, keyed by EPG channel id.
        @State private var nowTitles: [String: String] = [:]
        @State private var playlistPrefix = ""
        /// Debounces category-focus loads so sweeping down the rail doesn't
        /// fetch every category it passes.
        @State private var loadTask: Task<Void, Never>?

        @FocusState private var focus: FocusTarget?

        /// Doubles as the row identity for `ScrollViewProxy.scrollTo`.
        enum FocusTarget: Hashable {
            case section(String)
            case channel(String)
        }

        private var currentChannelID: String? {
            if case let .live(id) = media.contentRef { return id }
            return nil
        }

        var body: some View {
            ZStack(alignment: .leading) {
                scrim

                ScrollViewReader { proxy in
                    HStack(alignment: .top, spacing: 28) {
                        column(title: "Categories", width: 440) { categoryRows }
                        column(title: "Channels", width: 600) { channelRows }
                            // Fresh scroll position whenever another category's
                            // channels replace the list.
                            .id(selectedSectionID)
                    }
                    .padding(.leading, 80)
                    .padding(.vertical, 48)
                    .onAppear {
                        loadInitialContent()
                        landFocusOnCurrentChannel(proxy)
                    }
                }
            }
            .onChange(of: focus) { _, target in
                guard case let .section(id) = target, id != selectedSectionID else { return }
                scheduleChannelLoad(sectionID: id)
            }
            .onDisappear { loadTask?.cancel() }
        }

        // MARK: - Chrome

        private var scrim: some View {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.8), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.55),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        /// One scrollable glass column. Each column is its own focus section so
        /// left/right hop between the rails rather than walking row by row.
        private func column(
            title: LocalizedStringKey,
            width: CGFloat,
            @ViewBuilder rows: () -> some View
        ) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.top, 30)
                    .padding(.bottom, 14)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        rows()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 36))
            .focusSection()
        }

        // MARK: - Rows

        private var categoryRows: some View {
            ForEach(sections) { section in
                Button {
                    // Select already follows focus; a click just confirms.
                    scheduleChannelLoad(sectionID: section.id)
                } label: {
                    HStack(spacing: 12) {
                        if let icon = section.icon {
                            Image(systemName: icon)
                                .font(.system(size: 20, weight: .semibold))
                        }
                        Text(section.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVBrowserRowStyle(isSelected: section.id == selectedSectionID))
                .focused($focus, equals: .section(section.id))
                .id(FocusTarget.section(section.id))
            }
        }

        @ViewBuilder
        private var channelRows: some View {
            if channels.isEmpty {
                Text("No Channels")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ForEach(channels) { channel in
                    let isCurrent = channel.id == currentChannelID
                    Button {
                        select(channel: channel)
                    } label: {
                        channelLabel(channel, isCurrent: isCurrent)
                    }
                    .buttonStyle(TVBrowserRowStyle(isSelected: isCurrent))
                    .focused($focus, equals: .channel(channel.id))
                    .id(FocusTarget.channel(channel.id))
                }
            }
        }

        private func channelLabel(_ channel: LiveStream, isCurrent: Bool) -> some View {
            HStack(spacing: 16) {
                CachedAsyncImage(url: URL(string: channel.streamIcon ?? ""), maxPixelSize: 120) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fit).padding(6)
                    default:
                        Image(systemName: "tv")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 56)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .lineLimit(1)
                    if let nowTitle = channel.epgChannelId.flatMap({ nowTitles[$0] }) {
                        Text(nowTitle)
                            .font(.system(size: 20))
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
            }
        }

        // MARK: - Data

        /// Resolve the playing channel's playlist, build the section rail and
        /// fill the channel column with the current category's channels.
        private func loadInitialContent() {
            guard let stream = TVPlayerContent.liveStream(for: media.contentRef, in: modelContext),
                  let playlist = LiveChannelNavigator.playlist(for: stream, in: modelContext) else { return }
            playlistPrefix = "\(playlist.id.uuidString)-"

            let categorySort = CategorySortOption(rawValue: categorySortRaw) ?? .playlist
            let descriptor = FetchDescriptor<Category>(
                predicate: #Predicate { $0.typeRaw == "live" && $0.isHidden == false }
            )
            let categories = categorySort.sort(
                ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.id.hasPrefix(playlistPrefix) }
            )

            var rail: [LiveTVSection] = []
            if !fetchChannels(scope: .favorites).isEmpty { rail.append(.favorites) }
            if !fetchChannels(scope: .recentlyWatched).isEmpty { rail.append(.recentlyWatched) }
            rail.append(contentsOf: categories.map(LiveTVSection.category))
            sections = rail

            // Pre-select the playing channel's own category, not a virtual
            // section it may also appear in, so the rail mirrors where the
            // channel actually lives.
            let initialID = rail.first { $0.id == stream.categoryId }?.id ?? rail.first?.id
            selectedSectionID = initialID
            if let initialID, let section = rail.first(where: { $0.id == initialID }) {
                channels = fetchChannels(scope: section.scope)
                nowTitles = TVPlayerContent.nowProgrammeTitles(for: channels, in: modelContext)
            }
        }

        private func fetchChannels(scope: LiveChannelScope) -> [LiveStream] {
            let sort = ContentSortOption(rawValue: contentSortRaw) ?? .playlist
            let descriptor = LiveChannelQuery.descriptor(for: scope, sort: sort)
            let fetched = (try? modelContext.fetch(descriptor)) ?? []
            return LiveChannelQuery.scoped(fetched, scope: scope, playlistPrefix: playlistPrefix)
        }

        /// Swap the channel column to another section's channels. Debounced a
        /// touch so sweeping focus down the rail loads only where it rests, and
        /// deferred off the focus engine's animated context so the list swap
        /// doesn't pick up an implicit move animation.
        private func scheduleChannelLoad(sectionID: String) {
            guard sectionID != selectedSectionID else { return }
            loadTask?.cancel()
            loadTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled,
                      let section = sections.first(where: { $0.id == sectionID }) else { return }
                selectedSectionID = sectionID
                channels = fetchChannels(scope: section.scope)
                nowTitles = TVPlayerContent.nowProgrammeTitles(for: channels, in: modelContext)
            }
        }

        // MARK: - Focus

        /// Scroll both rails to the playing channel's position, then bind focus
        /// to its row. Deferred a tick so the lazy rows exist before focus asks
        /// for them; falls back to the selected category row when the channel
        /// isn't in the list (e.g. it was hidden since playback started).
        private func landFocusOnCurrentChannel(_ proxy: ScrollViewProxy) {
            Task { @MainActor in
                if let selectedSectionID {
                    proxy.scrollTo(FocusTarget.section(selectedSectionID), anchor: .center)
                }
                let channelTarget = currentChannelID.flatMap { id in
                    channels.contains { $0.id == id } ? FocusTarget.channel(id) : nil
                }
                if let channelTarget {
                    proxy.scrollTo(channelTarget, anchor: .center)
                }
                // Let the scroll realise the lazy rows before focusing one.
                try? await Task.sleep(nanoseconds: 60_000_000)
                if let channelTarget {
                    focus = channelTarget
                } else if let selectedSectionID {
                    focus = .section(selectedSectionID)
                }
            }
        }

        // MARK: - Actions

        private func select(channel stream: LiveStream) {
            guard stream.id != currentChannelID else {
                onClose()
                return
            }
            guard let playlist = LiveChannelNavigator.playlist(for: stream, in: modelContext),
                  let target = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
            onSelect(target)
        }
    }

    // MARK: - Row style

    /// A full-width list row for the browser columns: white glass highlight
    /// under focus (black content), a faint persistent fill for the selected
    /// category / playing channel, clear otherwise. The scale stays subtle so
    /// the lift survives the column's clipping.
    private struct TVBrowserRowStyle: ButtonStyle {
        var isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(fill, in: .rect(cornerRadius: 14))
                    .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1.0))
                    .animation(.easeOut(duration: 0.16), value: isFocused)
            }

            private var fill: AnyShapeStyle {
                if isFocused { return AnyShapeStyle(.white) }
                if isSelected { return AnyShapeStyle(.white.opacity(0.16)) }
                return AnyShapeStyle(.clear)
            }
        }
    }

#endif
