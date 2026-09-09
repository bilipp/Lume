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

enum LiveChannelQuery {
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
    static func descriptor(for scope: LiveChannelScope, sort: ContentSortOption) -> FetchDescriptor<LiveStream> {
        switch scope {
        case let .category(categoryId):
            return FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.categoryId == categoryId && $0.isHidden == false },
                sortBy: sort.liveStreamDescriptors
            )
        case .favorites:
            // `favoriteOrder` (nil-first) leads, exactly like `customOrder` for
            // categories: an un-reordered favorites list ties on nil and falls
            // through to the provider order, a reordered one sorts by the user's
            // arrangement. See ContentOrganizer.
            return FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.isFavorite && $0.isHidden == false },
                sortBy: [
                    SortDescriptor(\LiveStream.favoriteOrder),
                    SortDescriptor(\LiveStream.num),
                    SortDescriptor(\LiveStream.name)
                ]
            )
        case .recentlyWatched:
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.lastWatchedDate != nil && $0.isHidden == false },
                sortBy: [SortDescriptor(\LiveStream.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = recentLimit
            return descriptor
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
    static func favoritesProbe(playlistPrefix: String, restriction: ContentRestriction) -> FetchDescriptor<LiveStream> {
        let prefix = playlistPrefix
        let excluded = excludedCategoryIDs(restriction)
        let filtersCategories = !excluded.isEmpty
        return probe(
            predicate: #Predicate { stream in
                stream.isFavorite && stream.isHidden == false && stream.id.starts(with: prefix)
                    && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
            }
        )
    }

    /// The same probe for Recently Watched. Note it deliberately ignores
    /// `recentLimit`: the list is capped at 50, but "is there at least one" is
    /// unaffected by a cap.
    static func recentlyWatchedProbe(playlistPrefix: String, restriction: ContentRestriction) -> FetchDescriptor<LiveStream> {
        let prefix = playlistPrefix
        let excluded = excludedCategoryIDs(restriction)
        let filtersCategories = !excluded.isEmpty
        return probe(
            predicate: #Predicate { stream in
                stream.lastWatchedDate != nil && stream.isHidden == false && stream.id.starts(with: prefix)
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
        playlistPrefix: String,
        restriction: ContentRestriction
    ) -> [LiveStream] {
        switch scope {
        case .category:
            streams.excludingRestricted(restriction)
        case .favorites, .recentlyWatched:
            streams.filter { isVisible($0, playlistPrefix: playlistPrefix, restriction: restriction) }
        }
    }

    /// Whether any of `streams` survives the filtering `scoped` applies to the
    /// virtual collections — the in-memory statement of the rule the rail's
    /// probes hand to SQLite, for callers that already hold the rows. Shares
    /// `isVisible` with `scoped`, so the two can never disagree about whether a
    /// section that was offered then renders empty.
    static func containsVisible(
        _ streams: some Sequence<LiveStream>,
        playlistPrefix: String,
        restriction: ContentRestriction
    ) -> Bool {
        streams.contains { isVisible($0, playlistPrefix: playlistPrefix, restriction: restriction) }
    }

    /// The per-channel test the virtual collections apply: in the active
    /// playlist, and not in a category locked away from this viewer.
    private static func isVisible(
        _ stream: LiveStream,
        playlistPrefix: String,
        restriction: ContentRestriction
    ) -> Bool {
        stream.id.hasPrefix(playlistPrefix) && !restriction.hides(categoryID: stream.categoryId)
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
        playlistPrefix: String,
        restriction: ContentRestriction
    ) -> [Category] {
        categories.filter {
            $0.type == .live && $0.id.hasPrefix(playlistPrefix)
                && !$0.isHidden && !restriction.hides(categoryID: $0.id)
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
    private var cached: [LiveTVSection] = []

    func sections(
        categories: [Category],
        playlistPrefix: String,
        sort: CategorySortOption,
        restriction: ContentRestriction
    ) -> [LiveTVSection] {
        // No active playlist: the rail has no categories to show, exactly as
        // when the filter below found none.
        guard !playlistPrefix.isEmpty else { return [] }
        let key = Self.key(categories: categories, playlistPrefix: playlistPrefix, sort: sort, restriction: restriction)
        guard key != self.key else { return cached }
        let visible = LiveChannelQuery.visibleCategories(categories, playlistPrefix: playlistPrefix, restriction: restriction)
        cached = sort.sort(visible).map(LiveTVSection.category)
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
        playlistPrefix: String,
        sort: CategorySortOption,
        restriction: ContentRestriction
    ) -> String {
        var hasher = Hasher()
        hasher.combine(categories.count)
        for category in categories {
            hasher.combine(category.id)
            hasher.combine(category.name)
            hasher.combine(category.customOrder)
            hasher.combine(category.sortOrder)
        }
        return "\(playlistPrefix)|\(sort.rawValue)|\(restriction.visibilityToken)|\(hasher.finalize())"
    }
}

// MARK: - Rail sections

/// Resolves the Live TV rail — the two virtual collections, when the active
/// playlist has anything visible in them, above the synced categories — and
/// hands the result to `content`.
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

    private let playlistPrefix: String
    private let categorySections: [LiveTVSection]
    private let content: ([LiveTVSection]) -> Content

    init(
        playlistPrefix: String,
        restriction: ContentRestriction,
        categorySections: [LiveTVSection],
        @ViewBuilder content: @escaping ([LiveTVSection]) -> Content
    ) {
        self.playlistPrefix = playlistPrefix
        self.categorySections = categorySections
        self.content = content
        _favoriteProbe = Query(
            LiveChannelQuery.favoritesProbe(playlistPrefix: playlistPrefix, restriction: restriction)
        )
        _recentProbe = Query(
            LiveChannelQuery.recentlyWatchedProbe(playlistPrefix: playlistPrefix, restriction: restriction)
        )
    }

    /// The rail's entries: the virtual collections (when non-empty) pinned above
    /// the synced categories.
    private var sections: [LiveTVSection] {
        // An empty prefix means there is no active playlist at all, and
        // `starts(with: "")` matches every row — the guard the two `has…`
        // properties used to carry before the probes moved into SQL.
        guard !playlistPrefix.isEmpty else { return categorySections }
        var resolved: [LiveTVSection] = []
        if !favoriteProbe.isEmpty { resolved.append(.favorites) }
        if !recentProbe.isEmpty { resolved.append(.recentlyWatched) }
        resolved.append(contentsOf: categorySections)
        return resolved
    }

    var body: some View {
        content(sections)
    }
}
