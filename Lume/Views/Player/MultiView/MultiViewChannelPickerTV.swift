//
//  MultiViewChannelPickerTV.swift
//  Lume
//
//  The tvOS channel picker for a Multi-View tile. Deliberately not the iOS
//  sheet: `.searchable` on tvOS raises the full-screen keyboard, which covers
//  the picker outright and leaves nothing to navigate. This is the same shape as
//  the in-player channel browser instead — glass columns walked with the remote,
//  no text entry — with a leading Playlists column (Combined on top when it can
//  be entered), since reaching across playlists is the whole point of
//  Multi-View. It opens on the device's current selection.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct MultiViewChannelPickerTV: View {
        /// Channels already on screen, so they can be marked rather than offered
        /// twice.
        let usedMediaIDs: Set<String>
        /// Playlists already feeding another tile.
        let playlistsInUse: Set<UUID>
        var onPick: (PlayableMedia) -> Void

        @Environment(\.modelContext) private var modelContext
        @Environment(\.contentRestriction) private var restriction
        @AppStorage(SortStorageKey.liveCategories)
        private var categorySortRaw: String = CategorySortOption.playlist.rawValue
        @AppStorage(SortStorageKey.liveContent)
        private var contentSortRaw: String = ContentSortOption.playlist.rawValue
        @AppStorage(LiveTVRailSettings.showsFavoritesKey)
        private var showsFavorites = LiveTVRailSettings.showsFavoritesDefault
        @AppStorage(LiveTVRailSettings.showsRecentlyWatchedKey)
        private var showsRecentlyWatched = LiveTVRailSettings.showsRecentlyWatchedDefault
        @AppStorage(PlaylistSelectionStore.key) private var storedSelection: String = ""

        @State private var premium = PremiumManager.shared
        @State private var playlists: [Playlist] = []
        @State private var source: MultiViewPickerSource?
        @State private var sectionGroups: [LiveTVSectionGroup] = []
        @State private var selectedSectionID: String?
        @State private var channels: [LiveStream] = []
        /// Debounces category-focus loads so sweeping down the rail doesn't fetch
        /// every category it passes.
        @State private var channelLoadTask: Task<Void, Never>?

        @FocusState private var focus: FocusTarget?

        private enum FocusTarget: Hashable {
            case combined
            case playlist(UUID)
            case section(String)
            case channel(String)
        }

        private var catalogScope: CatalogScope? {
            playlists.multiViewScope(for: source, isPremium: premium.isPremium)
        }

        private var sections: [LiveTVSection] {
            sectionGroups.allSections
        }

        var body: some View {
            ZStack {
                // Its own cover, so this is the ground rather than a scrim.
                Color.black
                    .ignoresSafeArea()

                HStack(alignment: .top, spacing: 24) {
                    // A single playlist has nothing to choose between, and the
                    // column would only cost a focus hop on every pick.
                    if playlists.count > 1 {
                        column(title: "Playlists", width: 380) { playlistRows }
                    }
                    column(title: "Categories", width: 440) { sectionRows }
                    column(title: "Channels", width: 640) { channelRows }
                        // Fresh scroll position whenever another category's
                        // channels replace the list.
                        .id(selectedSectionID)
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 48)
            }
            .onAppear(perform: loadPlaylists)
            .onChange(of: focus) { _, target in
                switch target {
                case .combined where source != .combined:
                    select(.combined)
                case let .playlist(id) where source != .playlist(id):
                    select(.playlist(id))
                case let .section(id) where id != selectedSectionID:
                    scheduleChannelLoad(sectionID: id)
                default:
                    break
                }
            }
            .onDisappear { channelLoadTask?.cancel() }
        }

        // MARK: - Chrome

        /// One scrollable glass column, its own focus section so left/right hop
        /// between rails rather than walking row by row.
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

        @ViewBuilder
        private var playlistRows: some View {
            if let combined = playlists.multiViewCombinedScope(isPremium: premium.isPremium) {
                Button {
                    select(.combined)
                } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: PlaylistSelectionStore.combinedTitle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if combined.members(for: .liveTV).contains(where: playlistsInUse.contains) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .accessibilityLabel("Already streaming in another tile")
                        }
                    }
                }
                .buttonStyle(MultiViewPickerRowStyle(isSelected: source == .combined))
                .focused($focus, equals: .combined)
            }
            ForEach(playlists) { playlist in
                Button {
                    select(.playlist(playlist.id))
                } label: {
                    HStack(spacing: 12) {
                        Text(playlist.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // Providers commonly allow one connection per account, so
                        // flag a playlist another tile is already streaming.
                        if playlistsInUse.contains(playlist.id) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .accessibilityLabel("Already streaming in another tile")
                        }
                    }
                }
                .buttonStyle(MultiViewPickerRowStyle(isSelected: source == .playlist(playlist.id)))
                .focused($focus, equals: .playlist(playlist.id))
            }
        }

        @ViewBuilder
        private var sectionRows: some View {
            if sections.isEmpty {
                emptyLabel("No Channels")
            } else {
                ForEach(sectionGroups) { group in
                    if let title = group.title {
                        TVRailGroupHeader(title: title) {
                            if let playlistID = group.id, playlistsInUse.contains(playlistID) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .accessibilityLabel("Already streaming in another tile")
                            }
                        }
                    }
                    ForEach(group.sections) { section in
                        sectionButton(section)
                    }
                }
            }
        }

        private func sectionButton(_ section: LiveTVSection) -> some View {
            Button {
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
            .buttonStyle(MultiViewPickerRowStyle(isSelected: section.id == selectedSectionID))
            .focused($focus, equals: .section(section.id))
        }

        @ViewBuilder
        private var channelRows: some View {
            if channels.isEmpty {
                emptyLabel("No Channels")
            } else {
                ForEach(channels) { channel in
                    let isPlaying = usedMediaIDs.contains("live-\(channel.id)")
                    Button {
                        pick(channel)
                    } label: {
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

                            Text(channel.name)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if isPlaying {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .accessibilityLabel("Already playing")
                            }
                        }
                    }
                    .buttonStyle(MultiViewPickerRowStyle(isSelected: false))
                    .focused($focus, equals: .channel(channel.id))
                    .disabled(isPlaying)
                }
            }
        }

        private func emptyLabel(_ text: LocalizedStringKey) -> some View {
            Text(text)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        }

        // MARK: - Data

        private func loadPlaylists() {
            playlists = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
            if source == nil {
                source = MultiViewPickerSource(playlists.scope(for: storedSelection, isPremium: premium.isPremium))
            }
            loadSections()
            // Land focus on the categories rail once the lazy rows exist, or on
            // the current source when it has nothing to list. Deferred so the
            // write doesn't land inside the focus engine's animated context.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                if let selectedSectionID {
                    focus = .section(selectedSectionID)
                } else if playlists.count > 1 {
                    switch source {
                    case .combined: focus = .combined
                    case let .playlist(id): focus = .playlist(id)
                    case nil: break
                    }
                }
            }
        }

        private func select(_ newSource: MultiViewPickerSource) {
            source = newSource
            loadSections()
        }

        private func loadSections() {
            guard let playlistScope = catalogScope else {
                sectionGroups = []
                channels = []
                return
            }
            let sort = CategorySortOption(rawValue: categorySortRaw) ?? .playlist
            let descriptor = FetchDescriptor<Category>(
                predicate: #Predicate { $0.typeRaw == "live" && $0.isHidden == false }
            )
            let categories = sort.sort(
                LiveChannelQuery.visibleCategories(
                    (try? modelContext.fetch(descriptor)) ?? [],
                    catalogScope: playlistScope,
                    restriction: restriction
                )
            )

            var pinned: [LiveTVSection] = []
            if showsFavorites, !fetchChannels(scope: .favorites, catalogScope: playlistScope).isEmpty { pinned.append(.favorites) }
            if showsRecentlyWatched, !fetchChannels(scope: .recentlyWatched, catalogScope: playlistScope).isEmpty {
                pinned.append(.recentlyWatched)
            }
            sectionGroups = LiveTVSectionGroup.rail(
                pinned: pinned,
                categoryGroups: LiveTVSectionGroup.categoryGroups(
                    categories.map(LiveTVSection.category),
                    catalogScope: playlistScope,
                    playlistNames: playlists.namesByID
                )
            )

            let first = sections.first
            selectedSectionID = first?.id
            channels = first.map { fetchChannels(scope: $0.scope, catalogScope: playlistScope) } ?? []
        }

        /// Swap the channel column to another section's channels, debounced so
        /// sweeping focus down the rail loads only where it rests.
        private func scheduleChannelLoad(sectionID: String) {
            guard sectionID != selectedSectionID else { return }
            channelLoadTask?.cancel()
            channelLoadTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled,
                      let section = sections.first(where: { $0.id == sectionID }),
                      let catalogScope else { return }
                selectedSectionID = sectionID
                channels = fetchChannels(scope: section.scope, catalogScope: catalogScope)
            }
        }

        private func fetchChannels(scope: LiveChannelScope, catalogScope: CatalogScope) -> [LiveStream] {
            let sort = ContentSortOption(rawValue: contentSortRaw) ?? .playlist
            let descriptor = LiveChannelQuery.descriptor(for: scope, sort: sort)
            let fetched = (try? modelContext.fetch(descriptor)) ?? []
            // `scoped` applies the restriction itself — categories by their id,
            // the virtual collections per channel — so it must not be repeated.
            return LiveChannelQuery.scoped(fetched, scope: scope, catalogScope: catalogScope, restriction: restriction)
        }

        private func pick(_ stream: LiveStream) {
            guard let media = PlayableMedia.from(stream: stream, ownedByOneOf: playlists) else { return }
            onPick(media)
        }
    }

    // MARK: - Row style

    /// A full-width column row: white fill with black content under focus, a faint
    /// persistent fill for the selected playlist / category, clear otherwise.
    /// Mirrors the in-player channel browser's rows so the two read as one idiom.
    private struct MultiViewPickerRowStyle: ButtonStyle {
        var isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .opacity(isEnabled ? 1 : 0.45)
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
