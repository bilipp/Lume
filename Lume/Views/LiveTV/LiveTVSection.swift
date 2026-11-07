//
//  LiveTVSection.swift
//  Lume
//
//  The Live TV browse surfaces (the category rail / sidebar / bar and the
//  channel list / EPG guide) are driven by "sections" rather than raw
//  categories: alongside each synced live `Category` there are two virtual
//  collections — Favorites and Recently Watched — that cut across categories.
//
//  A `LiveTVSection` is what the user selects in the rail; a `LiveChannelScope`
//  is what the channel list / guide query against. `LiveChannelQuery` builds the
//  right `@Query` descriptor, the in-memory playlist scoping those lists need
//  (their predicate can't be parameterised on the playlist-prefixed id), and the
//  bounded probes that decide whether the virtual collections are offered at
//  all. `LiveTVSections` assembles the rail from both, `LiveTVCategoryMemo`
//  keeps its category half from being rebuilt on every body pass.
//

import SwiftData
import SwiftUI

// MARK: - Section

/// A selectable entry in the Live TV category rail. Either a real synced
/// category or one of the virtual cross-category collections.
enum LiveTVSection: Identifiable, Hashable {
    case favorites
    case recentlyWatched
    case category(Category)

    var id: String {
        switch self {
        case .favorites: "lume.liveSection.favorites"
        case .recentlyWatched: "lume.liveSection.recentlyWatched"
        case let .category(category): category.id
        }
    }

    var scope: LiveChannelScope {
        switch self {
        case .favorites: .favorites
        case .recentlyWatched: .recentlyWatched
        case let .category(category): .category(category.id)
        }
    }

    /// SF Symbol shown beside the virtual collections; nil for plain categories.
    var icon: String? {
        switch self {
        case .favorites: "heart.fill"
        case .recentlyWatched: "clock.arrow.circlepath"
        case .category: nil
        }
    }

    /// Display label. Virtual collections are localized; category names are the
    /// provider's verbatim strings.
    var titleText: Text {
        switch self {
        case .favorites: Text("Favorites")
        case .recentlyWatched: Text("Recently Watched")
        case let .category(category): Text(category.name)
        }
    }

    /// Plain title used where a `String` is needed (e.g. tvOS minimumScaleFactor
    /// rows that style the label themselves).
    var title: String {
        switch self {
        case .favorites: String(localized: "Favorites")
        case .recentlyWatched: String(localized: "Recently Watched")
        case let .category(category): category.name
        }
    }

    var isVirtual: Bool {
        switch self {
        case .favorites, .recentlyWatched: true
        case .category: false
        }
    }
}

// MARK: - Section groups

/// One block of the rail. With a single Live TV playlist in scope the rail is
/// one untitled group, exactly the list it was before Combined existed. With two
/// or more contributing members each one's categories form a group titled with
/// the playlist's name, in member priority order — categories are never merged
/// by name across playlists — below an untitled group for the virtual
/// collections, which span every member.
struct LiveTVSectionGroup: Identifiable, Hashable {
    /// The member playlist; nil for the pinned virtual collections.
    let id: UUID?
    let title: String?
    let sections: [LiveTVSection]
}

extension LiveTVSectionGroup {
    /// Splits the sorted category sections by owning member. Keeps the order
    /// within each member and drops members with nothing to show.
    static func categoryGroups(
        _ categories: [LiveTVSection],
        catalogScope: CatalogScope,
        playlistNames: [UUID: String]
    ) -> [LiveTVSectionGroup] {
        guard !categories.isEmpty, let first = catalogScope.members(for: .liveTV).first else { return [] }
        guard catalogScope.namesMembers(for: .liveTV) else {
            return [LiveTVSectionGroup(id: first, title: nil, sections: categories)]
        }
        return catalogScope.groupedByMember(categories, for: .liveTV, id: \.id).map { member, sections in
            LiveTVSectionGroup(id: member, title: playlistNames[member], sections: sections)
        }
    }

    /// The whole rail: `pinned` (the virtual collections) above the category
    /// groups. Untitled category groups absorb them, so a rail without
    /// headers stays one flat list.
    static func rail(pinned: [LiveTVSection], categoryGroups: [LiveTVSectionGroup]) -> [LiveTVSectionGroup] {
        guard !pinned.isEmpty else { return categoryGroups }
        guard categoryGroups.contains(where: { $0.title != nil }) else {
            let sections = pinned + categoryGroups.flatMap(\.sections)
            return [LiveTVSectionGroup(id: categoryGroups.first?.id, title: nil, sections: sections)]
        }
        return [LiveTVSectionGroup(id: nil, title: nil, sections: pinned)] + categoryGroups
    }
}

extension [LiveTVSectionGroup] {
    /// Every section in rail order, for selection and for the tvOS rail.
    var allSections: [LiveTVSection] {
        flatMap(\.sections)
    }

    var hasHeaders: Bool {
        contains { $0.title != nil }
    }
}

// MARK: - Scope

/// What a Live TV channel list / guide should show. Travels with a channel into
/// the player (`PlayableMedia.channelScope`) so in-player surfing stays inside
/// the list the viewer started from — see `LiveChannelNavigator`.
nonisolated enum LiveChannelScope: Hashable, Codable {
    /// Channels in a single synced category (carries the category id).
    case category(String)
    /// Every favorited channel in the active playlist.
    case favorites
    /// Recently watched channels in the active playlist, newest first.
    case recentlyWatched
}

// MARK: - Query

nonisolated enum LiveChannelQuery {
    /// Cap on the Recently Watched collection — watch history is naturally
    /// bounded but we don't want it to grow without limit.
    static let recentLimit = 50

    /// Channel lists mount in pages as they scroll. A live category can hold
    /// hundreds of channels; building every row — and resolving now/next EPG
    /// for every channel — before the first paint stalls the browse. The list
    /// renders a window that grows by this many channels as it nears the end.
    static let pageSize = 50

    /// Builds the `@Query` descriptor for a scope. The category scope sorts by
    /// the user's content-sort choice; the virtual collections have an intrinsic
    /// order (favorites by their own custom order, recents by most-recent-first).
    ///
    /// Recently Watched caps *before* `scoped(_:…)` drops the other playlists'
    /// rows, so the rail shows the part of the global newest `recentLimit` that
    /// belongs to the active playlist. In-player surfing reproduces that order of
    /// operations (`LiveChannelNavigator.recentsRing`) — move the prefix into
    /// this predicate and the two compositions diverge.
    static func descriptor(for scope: LiveChannelScope, sort: ContentSortOption) -> FetchDescriptor<LiveStream> {
        switch scope {
        case let .category(categoryId):
            return FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.categoryId == categoryId && $0.isHidden == false },
                sortBy: sortDescriptors(for: scope, sort: sort)
            )
        case .favorites:
            return FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.isFavorite && $0.isHidden == false },
                sortBy: sortDescriptors(for: scope, sort: sort)
            )
        case .recentlyWatched:
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.lastWatchedDate != nil && $0.isHidden == false },
                sortBy: sortDescriptors(for: scope, sort: sort)
            )
            descriptor.fetchLimit = recentLimit
            return descriptor
        }
    }

    /// The order a scope's channel list is in. Shared with in-player surfing
    /// (`LiveChannelNavigator`), which walks the same list one row at a time and
    /// would otherwise carry a second copy of these orderings — a copy that can
    /// drift, leaving the channel the buttons tune to next off by one from the
    /// channel sitting below it in the list the viewer browsed.
    static func sortDescriptors(
        for scope: LiveChannelScope, sort: ContentSortOption
    ) -> [SortDescriptor<LiveStream>] {
        switch scope {
        case .category:
            sort.liveStreamDescriptors
        case .favorites:
            // `favoriteOrder` (nil-first) leads, exactly like `customOrder` for
            // categories: an un-reordered favorites list ties on nil and falls
            // through to the provider order, a reordered one sorts by the user's
            // arrangement. See ContentOrganizer.
            [
                SortDescriptor(\LiveStream.favoriteOrder),
                SortDescriptor(\LiveStream.num),
                SortDescriptor(\LiveStream.name)
            ]
        case .recentlyWatched:
            [SortDescriptor(\LiveStream.lastWatchedDate, order: .reverse)]
        }
    }

    /// Whether the active playlist holds any favorite this viewer may see — the
    /// only thing the rail needs in order to decide whether to offer the
    /// Favorites section.
    ///
    /// Everything `isVisible` tests is in the predicate, so this materializes at
    /// most one row (measured: 0.02 ms). It has to: the rail used to answer the
    /// same question with an unbounded `@Query` per collection and filter the
    /// result in Swift — 1,506 favorites and 5,069 watched rows on a large
    /// playlist, 8-13 ms per evaluation, re-run 18-25 times on a cold launch of
    /// a tab the viewer may never open.
    ///
    /// The restriction *must* stay in the predicate rather than being applied to
    /// the fetched row afterwards. With `fetchLimit = 1` a Swift-side check
    /// would call the collection empty whenever the single row that came back
    /// happened to sit in a category this viewer can't see, silently dropping a
    /// section full of visible channels — so the excluded ids go to SQLite too.
    static func favoritesProbe(catalogScope: CatalogScope, restriction: ContentRestriction) -> FetchDescriptor<LiveStream> {
        let excluded = excludedCategoryIDs(restriction)
        let filtersCategories = !excluded.isEmpty
        if let prefix = catalogScope.singlePrefix(for: .liveTV) {
            return probe(
                predicate: #Predicate { stream in
                    stream.isFavorite && stream.isHidden == false && stream.id.starts(with: prefix)
                        && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
                }
            )
        }
        let scoped = catalogScope.liveStreamPredicate()
        return probe(
            predicate: #Predicate { stream in
                stream.isFavorite && stream.isHidden == false && scoped.evaluate(stream)
                    && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
            }
        )
    }

    /// The same probe for Recently Watched. Note it deliberately ignores
    /// `recentLimit`: the list is capped at 50, but "is there at least one" is
    /// unaffected by a cap.
    static func recentlyWatchedProbe(
        catalogScope: CatalogScope,
        restriction: ContentRestriction
    ) -> FetchDescriptor<LiveStream> {
        let excluded = excludedCategoryIDs(restriction)
        let filtersCategories = !excluded.isEmpty
        if let prefix = catalogScope.singlePrefix(for: .liveTV) {
            return probe(
                predicate: #Predicate { stream in
                    stream.lastWatchedDate != nil && stream.isHidden == false && stream.id.starts(with: prefix)
                        && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
                }
            )
        }
        let scoped = catalogScope.liveStreamPredicate()
        return probe(
            predicate: #Predicate { stream in
                stream.lastWatchedDate != nil && stream.isHidden == false && scoped.evaluate(stream)
                    && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
            }
        )
    }

    /// Wraps an existence predicate as a `LIMIT 1` fetch. No `sortBy` on
    /// purpose: a sort descriptor makes SQLite find and order every match before
    /// the limit can apply, which is exactly the work being avoided.
    private static func probe(predicate: Predicate<LiveStream>) -> FetchDescriptor<LiveStream> {
        var descriptor = FetchDescriptor<LiveStream>(predicate: predicate)
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// The categories hidden from this viewer, as optionals, so a predicate can
    /// test the optional `categoryId` against them directly: neither `?? ""` nor
    /// a nil-check plus force-unwrap survives SwiftData's SQL generation, while
    /// matching a `Set<String?>` builds a plain `IN` clause — the same shape the
    /// search predicates use (see `SearchScope.excludedOptional`).
    private static func excludedCategoryIDs(_ restriction: ContentRestriction) -> Set<String?> {
        Set(restriction.excludedCategoryIDs.map(String?.some))
    }

    /// Scopes a query's results to the active playlist *and* to what the current
    /// viewer is allowed to see. Category queries are already isolated (category
    /// ids are playlist-prefixed), but the virtual collections span every
    /// playlist, so they're filtered in-memory by the shared id prefix — the same
    /// approach used throughout the app.
    ///
    /// `restriction` is required rather than defaulted on purpose. Every channel
    /// list in the app funnels through here, so making the compiler demand it at
    /// each call site is what stops one surface from quietly shipping without the
    /// parental filter — which is exactly how the tvOS list and the in-player
    /// browser came to show a child channels from locked categories.
    ///
    /// The virtual collections need it most: Favorites and Recently Watched cut
    /// across categories, so a channel favorited before its category was locked
    /// would otherwise keep surfacing.
    static func scoped(
        _ streams: [LiveStream],
        scope: LiveChannelScope,
        catalogScope: CatalogScope,
        restriction: ContentRestriction
    ) -> [LiveStream] {
        switch scope {
        case .category:
            return streams.excludingRestricted(restriction)
        case .favorites, .recentlyWatched:
            let matcher = CatalogScope.Matcher(catalogScope)
            return streams.filter { isVisible($0, in: matcher, restriction: restriction) }
        }
    }

    /// Whether any of `streams` survives the filtering `scoped` applies to the
    /// virtual collections — the in-memory statement of the rule the rail's
    /// probes hand to SQLite, for callers that already hold the rows. Shares
    /// `isVisible` with `scoped`, so the two can never disagree about whether a
    /// section that was offered then renders empty.
    static func containsVisible(
        _ streams: some Sequence<LiveStream>,
        catalogScope: CatalogScope,
        restriction: ContentRestriction
    ) -> Bool {
        let matcher = CatalogScope.Matcher(catalogScope)
        return streams.contains { isVisible($0, in: matcher, restriction: restriction) }
    }

    /// The per-channel test the virtual collections apply: in a playlist of the
    /// scope, and not in a category locked away from this viewer. An empty
    /// scope matches nothing here, unlike `Matcher.contains` on its own.
    private static func isVisible(
        _ stream: LiveStream,
        in matcher: CatalogScope.Matcher,
        restriction: ContentRestriction
    ) -> Bool {
        !matcher.scope.isEmpty && matcher.contains(stream.id, .liveTV)
            && !restriction.hides(categoryID: stream.categoryId)
    }

    /// The live categories of the active playlist this viewer may see: scoped by
    /// playlist prefix, minus the ones hidden in Content Management, minus the
    /// ones locked away from a child profile.
    ///
    /// Shared by the Live TV rail and the in-player channel browser so the two
    /// cannot disagree about what a category rail contains — the browser used to
    /// drop only `isHidden`, which put locked categories one remote press away
    /// from a child mid-playback.
    static func visibleCategories(
        _ categories: [Category],
        catalogScope: CatalogScope,
        restriction: ContentRestriction
    ) -> [Category] {
        guard !catalogScope.isEmpty else { return [] }
        let matcher = CatalogScope.Matcher(catalogScope)
        return categories.filter { category in
            category.type == .live && matcher.contains(category.id, .liveTV)
                && !category.isHidden && !restriction.hides(categoryID: category.id)
        }
    }
}

// MARK: - Category memo

/// Memo for the rail's category sections, held by the browse screen for as long
/// as it lives.
///
/// Filtering the live categories by playlist prefix and viewer restriction and
/// then sorting them is cheap once and expensive 25 times: the sort alone reads
/// three or four properties off a managed object per comparison, so ~900
/// categories cost tens of thousands of SwiftData property reads per body pass,
/// and `LiveTVView`'s body runs 18-25 times on a cold launch. The work now
/// happens once per change of the inputs it depends on; every other pass reads
/// the array back.
///
/// Keyed rather than invalidated, for the reason `HomeTrendingCache` spells
/// out: an entry is only ever returned when its key still matches the inputs
/// that produced it, so an array holding `Category` objects a playlist deletion
/// has since removed can never be handed back and rendered.
@MainActor
final class LiveTVCategoryMemo {
    private var key = ""
    private var cached: [LiveTVSectionGroup] = []

    func groups(
        categories: [Category],
        catalogScope: CatalogScope,
        playlistNames: [UUID: String],
        sort: CategorySortOption,
        restriction: ContentRestriction
    ) -> [LiveTVSectionGroup] {
        // No active playlist: the rail has no categories to show, exactly as
        // when the filter below found none.
        guard !catalogScope.isEmpty else { return [] }
        let key = Self.key(
            categories: categories,
            catalogScope: catalogScope,
            playlistNames: playlistNames,
            sort: sort,
            restriction: restriction
        )
        guard key != self.key else { return cached }
        let visible = LiveChannelQuery.visibleCategories(categories, catalogScope: catalogScope, restriction: restriction)
        cached = LiveTVSectionGroup.categoryGroups(
            sort.sort(visible).map(LiveTVSection.category),
            catalogScope: catalogScope,
            playlistNames: playlistNames
        )
        self.key = key
        return cached
    }

    /// Everything the filter and the sort read, folded into one token.
    ///
    /// The per-category loop is not just about detecting change: reading these
    /// properties inside `body` is what registers SwiftUI's observation of them,
    /// and a pass that skipped it would stop observing — a reorder in Content
    /// Management (which rewrites `customOrder` without changing how many
    /// categories there are) would then never reach the rail. It stays far
    /// cheaper than the sort it replaces, which reads the same fields once per
    /// comparison rather than once per category.
    private static func key(
        categories: [Category],
        catalogScope: CatalogScope,
        playlistNames: [UUID: String],
        sort: CategorySortOption,
        restriction: ContentRestriction
    ) -> String {
        var hasher = Hasher()
        for id in catalogScope.members(for: .liveTV) {
            hasher.combine(playlistNames[id])
        }
        hasher.combine(categories.count)
        for category in categories {
            hasher.combine(category.id)
            hasher.combine(category.name)
            hasher.combine(category.customOrder)
            hasher.combine(category.sortOrder)
        }
        return "\(catalogScope.token)|\(sort.rawValue)|\(restriction.visibilityToken)|\(hasher.finalize())"
    }
}

// MARK: - Rail sections

/// Resolves the Live TV rail — the two virtual collections, when the active
/// playlist has anything visible in them and Settings › Live TV hasn't switched
/// them off, above the synced categories — and hands the result to `content`.
///
/// The gates live here, in a child view, because a `@Query`'s descriptor is
/// fixed at `init` and `LiveTVView` is a tab root whose `init` does not re-run
/// when the selected playlist changes; this view is rebuilt by that body, so its
/// probes always describe the playlist currently on screen. Resolving them as
/// `@Query`s (rather than a fetch in a task) is what keeps the rail reacting to
/// a channel being favorited or watched without a second render pass.
struct LiveTVSections<Content: View>: View {
    @Query private var favoriteProbe: [LiveStream]
    @Query private var recentProbe: [LiveStream]
    @AppStorage(LiveTVRailSettings.showsFavoritesKey)
    private var showsFavorites = LiveTVRailSettings.showsFavoritesDefault
    @AppStorage(LiveTVRailSettings.showsRecentlyWatchedKey)
    private var showsRecentlyWatched = LiveTVRailSettings.showsRecentlyWatchedDefault

    private let catalogScope: CatalogScope
    private let categoryGroups: [LiveTVSectionGroup]
    private let content: ([LiveTVSectionGroup]) -> Content

    init(
        catalogScope: CatalogScope,
        restriction: ContentRestriction,
        categoryGroups: [LiveTVSectionGroup],
        @ViewBuilder content: @escaping ([LiveTVSectionGroup]) -> Content
    ) {
        self.catalogScope = catalogScope
        self.categoryGroups = categoryGroups
        self.content = content
        _favoriteProbe = Query(
            LiveChannelQuery.favoritesProbe(catalogScope: catalogScope, restriction: restriction)
        )
        _recentProbe = Query(
            LiveChannelQuery.recentlyWatchedProbe(catalogScope: catalogScope, restriction: restriction)
        )
    }

    /// The rail's entries: the virtual collections (when non-empty) pinned above
    /// the synced categories.
    private var groups: [LiveTVSectionGroup] {
        // No active playlist at all: the guard the two `has…` properties used
        // to carry before the probes moved into SQL.
        guard !catalogScope.isEmpty else { return categoryGroups }
        var pinned: [LiveTVSection] = []
        if showsFavorites, !favoriteProbe.isEmpty { pinned.append(.favorites) }
        if showsRecentlyWatched, !recentProbe.isEmpty { pinned.append(.recentlyWatched) }
        return LiveTVSectionGroup.rail(pinned: pinned, categoryGroups: categoryGroups)
    }

    var body: some View {
        content(groups)
    }
}
