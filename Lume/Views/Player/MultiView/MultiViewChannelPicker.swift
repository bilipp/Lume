//
//  MultiViewChannelPicker.swift
//  Lume
//
//  Picks the channel for one Multi-View tile. Unlike the Live TV browser this is
//  deliberately not scoped to the globally selected playlist: watching two
//  streams at once is often only possible *across* playlists, because providers
//  commonly allow a single concurrent connection per account. The playlist a
//  tile already streams from is flagged for that reason.
//

import SwiftData
import SwiftUI

struct MultiViewChannelPicker: View {
    /// Channels already on screen, so they can be marked rather than offered
    /// twice.
    let usedMediaIDs: Set<String>
    /// Playlists already feeding another tile.
    let playlistsInUse: Set<UUID>
    var onPick: (PlayableMedia) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "live" && $0.isHidden == false })
    private var categories: [Category]

    @AppStorage(SortStorageKey.liveCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue

    @State private var playlistID: UUID?
    @State private var search = ""
    /// Search hits across the selected playlist. Empty while not searching.
    @State private var matches: [LiveStream] = []
    /// The term `matches` was actually fetched for. Stays empty until the first
    /// debounced fetch settles, so "no results" can't flash under the viewer
    /// while they are still typing.
    @State private var settledTerm = ""

    private var selectedPlaylist: Playlist? {
        playlists.first { $0.id == playlistID } ?? playlists.first
    }

    private var searchTerm: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live categories of the selected playlist, in the user's category order.
    private var scopedCategories: [Category] {
        guard let playlist = selectedPlaylist else { return [] }
        let prefix = "\(playlist.id.uuidString)-"
        let sort = CategorySortOption(rawValue: categorySortRaw) ?? .playlist
        return sort.sort(categories.filter { $0.id.hasPrefix(prefix) && !restriction.hides(categoryID: $0.id) })
    }

    var body: some View {
        NavigationStack {
            List {
                if playlists.count > 1 {
                    playlistSection
                }

                if !searchTerm.isEmpty {
                    searchResultsSection
                } else if scopedCategories.isEmpty {
                    ContentUnavailableView(
                        "No Channels",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Sync this playlist to load live TV channels")
                    )
                } else {
                    categorySection
                }
            }
            .navigationTitle("Add Channel")
            .searchable(text: $search, prompt: "Search channels")
            #if !os(tvOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            #endif
                .task {
                    if playlistID == nil {
                        playlistID = playlists.first?.id
                    }
                }
                .task(id: "\(playlistID?.uuidString ?? "")-\(searchTerm)") { await loadMatches() }
        }
    }

    // MARK: - Sections

    private var playlistSection: some View {
        Section {
            Picker("Playlist", selection: Binding(
                get: { selectedPlaylist?.id },
                set: { playlistID = $0 }
            )) {
                ForEach(playlists) { playlist in
                    Text(playlist.name).tag(Optional(playlist.id))
                }
            }
            if let id = selectedPlaylist?.id, playlistsInUse.contains(id) {
                Label(
                    "Another tile is already streaming this playlist. Many providers allow only one connection at a time — pick a different playlist if the stream won't start.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var categorySection: some View {
        Section("Categories") {
            ForEach(scopedCategories) { category in
                NavigationLink(category.name) {
                    MultiViewPickerCategoryChannels(
                        category: category,
                        playlist: selectedPlaylist,
                        usedMediaIDs: usedMediaIDs,
                        onPick: pick
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if matches.isEmpty {
            // Only once a query has actually been run — the fetch is debounced,
            // and without this the empty state showed for the length of every
            // pause in typing.
            if !settledTerm.isEmpty {
                ContentUnavailableView.search(text: settledTerm)
            }
        } else {
            Section("Channels") {
                ForEach(matches) { stream in
                    MultiViewPickerChannelRow(
                        stream: stream,
                        playlist: selectedPlaylist,
                        usedMediaIDs: usedMediaIDs,
                        onPick: pick
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func pick(_ media: PlayableMedia) {
        onPick(media)
        dismiss()
    }

    /// Searches the selected playlist's channels by name, debounced and off the
    /// view context.
    ///
    /// This runs while Multi-View holds up to four live decoders — the tightest
    /// main-thread budget the app has — and it used to fire a synchronous
    /// main-context fetch on *every keystroke*: a `localizedStandardContains`
    /// scan of all 60,093 channels carrying a *second* `NSCoreDataStringSearch`
    /// per row, because the playlist scope was a substring search on
    /// `categoryId`, and ordered by name so SQLite had to find and sort every
    /// match before `fetchLimit` could apply.
    ///
    /// All four are gone: `.task(id:)` cancels the sleep below the instant the
    /// term changes, so the fetch only fires once typing pauses; it runs on its
    /// own background context and hands back identifiers, which is the shape
    /// `SearchFetcher` established for the global search; the playlist scope is
    /// a range seek on the `starts(with:)` prefix of the unique — and therefore
    /// indexed — `id` every catalog row carries; and with no `sortBy:` the scan
    /// stops at the 200th hit instead of sorting the whole match set. The name
    /// order the list has always shown is applied over those 200 rows instead.
    private func loadMatches() async {
        guard !searchTerm.isEmpty, let playlist = selectedPlaylist else {
            settledTerm = ""
            matches = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let term = searchTerm
        let prefix = "\(playlist.id.uuidString)-"
        let container = modelContext.container
        let ids = await Task.detached(priority: .userInitiated) {
            MultiViewChannelSearch.hits(container: container, term: term, playlistPrefix: prefix)
        }.value
        guard !Task.isCancelled else { return }

        settledTerm = term
        matches = ids.compactMap { modelContext.model(for: $0) as? LiveStream }
            .excludingRestricted(restriction)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Off-main search fetch

/// The picker's channel search, run on its own background `ModelContext` and
/// returning only identifiers — managed objects can't cross an actor boundary.
/// Mirrors `SearchFetcher`, which does the same for the global search screen.
private nonisolated enum MultiViewChannelSearch {
    /// Cap on the rows one search returns, unchanged from the fetch this
    /// replaced. It only bites now: with an `ORDER BY` SQLite had to find and
    /// sort every match before the limit could apply, so a bounded fetch still
    /// walked all 60,093 channels; without one it stops at the 200th hit.
    static let limit = 200

    static func hits(container: ModelContainer, term: String, playlistPrefix: String) -> [PersistentIdentifier] {
        var descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { stream in
                stream.isHidden == false
                    && stream.name.localizedStandardContains(term)
                    && stream.id.starts(with: playlistPrefix)
            }
        )
        descriptor.fetchLimit = limit
        return ((try? ModelContext(container).fetch(descriptor)) ?? []).map(\.persistentModelID)
    }
}

// MARK: - Category channels

/// The channels of one category, in the order the viewer sees them in Live TV.
private struct MultiViewPickerCategoryChannels: View {
    let category: Category
    let playlist: Playlist?
    let usedMediaIDs: Set<String>
    var onPick: (PlayableMedia) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @AppStorage(SortStorageKey.liveContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    @State private var channels: [LiveStream] = []

    var body: some View {
        List {
            if channels.isEmpty {
                ContentUnavailableView(
                    "No Channels",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("This category has no channels")
                )
            } else {
                ForEach(channels) { stream in
                    MultiViewPickerChannelRow(
                        stream: stream,
                        playlist: playlist,
                        usedMediaIDs: usedMediaIDs,
                        onPick: onPick
                    )
                }
            }
        }
        .navigationTitle(category.name)
        .task(id: "\(category.id)-\(contentSortRaw)") { load() }
    }

    private func load() {
        let sort = ContentSortOption(rawValue: contentSortRaw) ?? .playlist
        let descriptor = LiveChannelQuery.descriptor(for: .category(category.id), sort: sort)
        channels = ((try? modelContext.fetch(descriptor)) ?? []).excludingRestricted(restriction)
    }
}

// MARK: - Row

private struct MultiViewPickerChannelRow: View {
    let stream: LiveStream
    let playlist: Playlist?
    let usedMediaIDs: Set<String>
    var onPick: (PlayableMedia) -> Void

    private var isPlaying: Bool {
        usedMediaIDs.contains("live-\(stream.id)")
    }

    var body: some View {
        Button {
            guard let playlist, let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
            onPick(media)
        } label: {
            HStack {
                LiveStreamCardView(stream: stream, epg: nil)
                if isPlaying {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPlaying)
    }
}
