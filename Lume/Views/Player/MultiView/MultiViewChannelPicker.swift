//
//  MultiViewChannelPicker.swift
//  Lume
//
//  Picks the channel for one Multi-View tile. It opens on the device's current
//  selection, but unlike the Live TV browser it is deliberately free to switch:
//  watching two streams at once is often only possible *across* playlists,
//  because providers commonly allow a single concurrent connection per account.
//  The playlist a tile already streams from is flagged for that reason.
//

import SwiftData
import SwiftUI

/// What a Multi-View picker lists channels from: one playlist, or every member
/// of the Combined selection grouped by playlist.
enum MultiViewPickerSource: Hashable {
    case combined
    case playlist(UUID)

    /// The source matching the device's resolved selection.
    init?(_ scope: CatalogScope) {
        if scope.isCombined {
            self = .combined
        } else if let id = scope.primaryID {
            self = .playlist(id)
        } else {
            return nil
        }
    }
}

extension [Playlist] {
    /// The scope a Multi-View picker source reads. Combined resolves exactly as
    /// the content tabs do, so a lapsed or shrunken config falls back to its
    /// priority-1 member rather than to nothing.
    func multiViewScope(for source: MultiViewPickerSource?, isPremium: Bool) -> CatalogScope? {
        switch source {
        case .combined:
            scope(for: PlaylistSelectionStore.combined, isPremium: isPremium)
        case let .playlist(id):
            contains { $0.id == id } ? .isolated(id) : nil
        case nil:
            nil
        }
    }

    /// The Combined scope when it can be entered, for offering the entry.
    func multiViewCombinedScope(isPremium: Bool) -> CatalogScope? {
        let scope = scope(for: PlaylistSelectionStore.combined, isPremium: isPremium)
        return scope.isCombined ? scope : nil
    }
}

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
    @AppStorage(PlaylistSelectionStore.key) private var storedSelection: String = ""

    @State private var premium = PremiumManager.shared
    @State private var source: MultiViewPickerSource?
    @State private var search = ""
    /// Search hits across the selected playlist. Empty while not searching.
    @State private var matches: [LiveStream] = []
    /// The term `matches` was actually fetched for. Stays empty until the first
    /// debounced fetch settles, so "no results" can't flash under the viewer
    /// while they are still typing.
    @State private var settledTerm = ""
    @State private var categoryMemo = LiveTVCategoryMemo()

    private var catalogScope: CatalogScope? {
        playlists.multiViewScope(for: source, isPremium: premium.isPremium)
    }

    /// The single playlist feeding the list, flagged as a whole when another
    /// tile streams it. With several, each member's header carries the flag.
    private func singleLiveMember(in scope: CatalogScope?) -> UUID? {
        guard let members = scope?.members(for: .liveTV), members.count == 1 else { return nil }
        return members[0]
    }

    private var searchTerm: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live categories of the selected source in the user's category order,
    /// one group per member — titled only when two or more contribute Live TV.
    private func categoryGroups(in scope: CatalogScope?) -> [LiveTVSectionGroup] {
        guard let scope else { return [] }
        return categoryMemo.groups(
            categories: categories,
            catalogScope: scope,
            playlistNames: playlists.namesByID,
            sort: CategorySortOption(rawValue: categorySortRaw) ?? .playlist,
            restriction: restriction
        )
    }

    var body: some View {
        let scope = catalogScope
        let groups = categoryGroups(in: scope)
        NavigationStack {
            List {
                if playlists.count > 1 {
                    playlistSection(singleLiveMember: singleLiveMember(in: scope))
                }

                if !searchTerm.isEmpty {
                    searchResultsSection(scope)
                } else if groups.isEmpty {
                    ContentUnavailableView(
                        "No Channels",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Sync this playlist to load live TV channels")
                    )
                } else {
                    categorySections(groups)
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
                    if source == nil {
                        source = MultiViewPickerSource(playlists.scope(for: storedSelection, isPremium: premium.isPremium))
                    }
                }
                .task(id: "\(scope?.token ?? "")-\(searchTerm)") { await loadMatches() }
        }
    }

    // MARK: - Sections

    private func playlistSection(singleLiveMember: UUID?) -> some View {
        Section {
            Picker("Playlist", selection: $source) {
                if playlists.multiViewCombinedScope(isPremium: premium.isPremium) != nil {
                    Text(verbatim: PlaylistSelectionStore.combinedTitle).tag(Optional(MultiViewPickerSource.combined))
                }
                ForEach(playlists) { playlist in
                    Text(playlist.name).tag(Optional(MultiViewPickerSource.playlist(playlist.id)))
                }
            }
            if let id = singleLiveMember, playlistsInUse.contains(id) {
                Label(
                    "Another tile is already streaming this playlist. Many providers allow only one connection at a time — pick a different playlist if the stream won't start.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func categorySections(_ groups: [LiveTVSectionGroup]) -> some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.sections) { section in
                    if case let .category(category) = section {
                        NavigationLink(category.name) {
                            MultiViewPickerCategoryChannels(
                                category: category,
                                playlists: playlists,
                                usedMediaIDs: usedMediaIDs,
                                onPick: pick
                            )
                        }
                    }
                }
            } header: {
                if let title = group.title {
                    memberHeader(title, playlistID: group.id)
                } else {
                    Text("Categories")
                }
            }
        }
    }

    private func memberHeader(_ title: String, playlistID: UUID?) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
            if let playlistID, playlistsInUse.contains(playlistID) {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityLabel("Already streaming in another tile")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Search hits split by member in priority order when two or more members
    /// contribute Live TV; one untitled group otherwise.
    private func matchGroups(in scope: CatalogScope?) -> [(id: UUID?, title: String?, streams: [LiveStream])] {
        guard let scope, scope.namesMembers(for: .liveTV) else { return [(id: nil, title: nil, streams: matches)] }
        let names = playlists.namesByID
        return scope.groupedByMember(matches, for: .liveTV, id: \.id).map { member, streams in
            (id: member, title: names[member], streams: streams)
        }
    }

    @ViewBuilder
    private func searchResultsSection(_ scope: CatalogScope?) -> some View {
        if matches.isEmpty {
            // Only once a query has actually been run — the fetch is debounced,
            // and without this the empty state showed for the length of every
            // pause in typing.
            if !settledTerm.isEmpty {
                ContentUnavailableView.search(text: settledTerm)
            }
        } else {
            ForEach(matchGroups(in: scope), id: \.id) { group in
                Section {
                    ForEach(group.streams) { stream in
                        MultiViewPickerChannelRow(
                            stream: stream,
                            playlists: playlists,
                            usedMediaIDs: usedMediaIDs,
                            onPick: pick
                        )
                    }
                } header: {
                    if let title = group.title {
                        memberHeader(title, playlistID: group.id)
                    } else {
                        Text("Channels")
                    }
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
        guard !searchTerm.isEmpty, let catalogScope, !catalogScope.members(for: .liveTV).isEmpty else {
            settledTerm = ""
            matches = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let term = searchTerm
        let container = modelContext.container
        let ids = await Task.detached(priority: .userInitiated) {
            MultiViewChannelSearch.hits(container: container, term: term, catalogScope: catalogScope)
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

    static func hits(container: ModelContainer, term: String, catalogScope: CatalogScope) -> [PersistentIdentifier] {
        var descriptor = FetchDescriptor<LiveStream>(predicate: predicate(term: term, catalogScope: catalogScope))
        descriptor.fetchLimit = limit
        return ((try? ModelContext(container).fetch(descriptor)) ?? []).map(\.persistentModelID)
    }

    private static func predicate(term: String, catalogScope: CatalogScope) -> Predicate<LiveStream> {
        if let prefix = catalogScope.singlePrefix(for: .liveTV) {
            return #Predicate { stream in
                stream.isHidden == false
                    && stream.name.localizedStandardContains(term)
                    && stream.id.starts(with: prefix)
            }
        }
        let scoped = catalogScope.liveStreamPredicate()
        return #Predicate { stream in
            stream.isHidden == false
                && stream.name.localizedStandardContains(term)
                && scoped.evaluate(stream)
        }
    }
}

// MARK: - Category channels

/// The channels of one category, in the order the viewer sees them in Live TV.
private struct MultiViewPickerCategoryChannels: View {
    let category: Category
    let playlists: [Playlist]
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
                        playlists: playlists,
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
    let playlists: [Playlist]
    let usedMediaIDs: Set<String>
    var onPick: (PlayableMedia) -> Void

    private var isPlaying: Bool {
        usedMediaIDs.contains("live-\(stream.id)")
    }

    var body: some View {
        Button {
            guard let media = PlayableMedia.from(stream: stream, ownedByOneOf: playlists) else { return }
            onPick(media)
        } label: {
            HStack {
                LiveStreamCardView(stream: stream, epg: nil)
                    .environment(\.playlistProvenance, .none)
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
