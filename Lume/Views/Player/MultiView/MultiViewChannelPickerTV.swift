//
//  MultiViewChannelPickerTV.swift
//  Lume
//
//  The tvOS channel picker for a Multi-View tile. Deliberately not the iOS
//  sheet: `.searchable` on tvOS raises the full-screen keyboard, which covers
//  the picker outright and leaves nothing to navigate. This is the same shape as
//  the in-player channel browser instead — glass columns walked with the remote,
//  no text entry — with a leading Playlists column, since reaching across
//  playlists is the whole point of Multi-View.
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

        @State private var playlists: [Playlist] = []
        @State private var selectedPlaylistID: UUID?
        @State private var sections: [LiveTVSection] = []
        @State private var selectedSectionID: String?
        @State private var channels: [LiveStream] = []
        /// Debounces category-focus loads so sweeping down the rail doesn't fetch
        /// every category it passes.
        @State private var channelLoadTask: Task<Void, Never>?

        @FocusState private var focus: FocusTarget?

        private enum FocusTarget: Hashable {
            case playlist(UUID)
            case section(String)
            case channel(String)
        }

        private var selectedPlaylist: Playlist? {
            playlists.first { $0.id == selectedPlaylistID }
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
                case let .playlist(id) where id != selectedPlaylistID:
                    selectedPlaylistID = id
                    loadSections()
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

        private var playlistRows: some View {
            ForEach(playlists) { playlist in
                Button {
                    selectedPlaylistID = playlist.id
                    loadSections()
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
                .buttonStyle(MultiViewPickerRowStyle(isSelected: playlist.id == selectedPlaylistID))
                .focused($focus, equals: .playlist(playlist.id))
            }
        }

        @ViewBuilder
        private var sectionRows: some View {
            if sections.isEmpty {
                emptyLabel("No Channels")
            } else {
                ForEach(sections) { section in
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
            }
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
            if selectedPlaylistID == nil {
                selectedPlaylistID = playlists.first?.id
            }
            loadSections()
            // Land focus on the categories rail once the lazy rows exist. Deferred
            // so the write doesn't land inside the focus engine's animated context.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                if let selectedSectionID {
                    focus = .section(selectedSectionID)
                } else if let first = playlists.first {
                    focus = .playlist(first.id)
                }
            }
        }

        private func loadSections() {
            guard let playlist = selectedPlaylist else {
                sections = []
                channels = []
                return
            }
            let prefix = "\(playlist.id.uuidString)-"
            let sort = CategorySortOption(rawValue: categorySortRaw) ?? .playlist
            let descriptor = FetchDescriptor<Category>(
                predicate: #Predicate { $0.typeRaw == "live" && $0.isHidden == false }
            )
            let categories = sort.sort(
                LiveChannelQuery.visibleCategories(
                    (try? modelContext.fetch(descriptor)) ?? [],
                    playlistPrefix: prefix,
                    restriction: restriction
                )
            )

            var rail: [LiveTVSection] = []
            if !fetchChannels(scope: .favorites, prefix: prefix).isEmpty { rail.append(.favorites) }
            if !fetchChannels(scope: .recentlyWatched, prefix: prefix).isEmpty { rail.append(.recentlyWatched) }
            rail.append(contentsOf: categories.map(LiveTVSection.category))
            sections = rail

            selectedSectionID = rail.first?.id
            channels = rail.first.map { fetchChannels(scope: $0.scope, prefix: prefix) } ?? []
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
                      let playlist = selectedPlaylist else { return }
                selectedSectionID = sectionID
                channels = fetchChannels(scope: section.scope, prefix: "\(playlist.id.uuidString)-")
            }
        }

        private func fetchChannels(scope: LiveChannelScope, prefix: String) -> [LiveStream] {
            let sort = ContentSortOption(rawValue: contentSortRaw) ?? .playlist
            let descriptor = LiveChannelQuery.descriptor(for: scope, sort: sort)
            let fetched = (try? modelContext.fetch(descriptor)) ?? []
            // `scoped` applies the restriction itself — categories by their id,
            // the virtual collections per channel — so it must not be repeated.
            return LiveChannelQuery.scoped(fetched, scope: scope, playlistPrefix: prefix, restriction: restriction)
        }

        private func pick(_ stream: LiveStream) {
            guard let playlist = selectedPlaylist,
                  let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
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
