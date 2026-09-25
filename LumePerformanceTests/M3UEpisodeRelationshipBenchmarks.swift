//
//  M3UEpisodeRelationshipBenchmarks.swift
//  LumePerformanceTests
//
//  Attribution, not optimisation. `LumePerformanceTests/README.md` names the
//  `Episode` → `Series` relationship the single largest *unmeasured* item on the
//  m3u cold path — ~1.48M `Episode.series` assignments, each of which can fault
//  the `Series.episodes` inverse — and defers it because nobody has isolated the
//  cost. These two suites isolate it, plus the other unverified claim on the
//  same loop: that the two per-batch IN-clause fetches stay cheap once the
//  tables reach provider scale.
//
//  Both drive on-disk stores (`PerfStore`). An in-memory container skips SQLite,
//  which is the entire cost under measurement, and it also skips the inverse's
//  fault — the row it would fault is already resident.
//
//  The upsert loops here are hand-written copies of `importEpisodes`, which is
//  private and driven by a streaming parse. They keep the production write shape
//  exactly: one fresh, autosave-off `ModelContext` per batch, `batchSize` 2000,
//  the per-batch series cache, dirty-checked field application, and `save()`
//  only when `context.hasChanges`. The two existing-row lookups are the shipped
//  ones, called through a `ContentSyncManager`. Keep the rest in step with
//  `ContentSyncManager+M3U.importEpisodes` by hand.
//
//  Measured 2026-09-08, iPhone 17 Pro simulator (iOS 26.4), 150,000 episodes:
//  file order 126.30 s / 652 MB, grouped by series 126.27 s / 622 MB,
//  interleaved 126.60 s / 868 MB, `series:` never assigned 21.62 s / 95 MB.
//  The relationship is 82.9% of the time and 85% of the peak; reordering the
//  batch moves neither, because a provider file is already grouped.
//
//  What does move it is *when* the relationship is attached, added the same
//  day: `.assignSeriesAfterInsert` writes the identical catalog — all 150,000
//  inverses verified attached — in 25.10 s / 74 MB, against 125.53 s / 557 MB
//  for file order measured back to back on the same machine. The cost was never
//  the inverse fault; it was `insert` migrating a relationship that was already
//  wired on an unregistered instance. `importEpisodes` now writes the two
//  statements in that order. The full write-up is in
//  `LumePerformanceTests/README.md`, "The m3u cold path, measured end to end".
//

import Foundation
@testable import Lume
import SwiftData
import XCTest

// MARK: - Episode plan

/// The episode stream a provider file hands the importer, in file order, as
/// compact records rather than parsed `M3UEntry` values.
///
/// Built from `ProviderEpisodeWalk` and `PerfFixtures.providerShowDescriptors`
/// — the same walk and the same show identities `writeProviderVODEntries`
/// emits, so this suite and the cold-import benchmark cannot drift into
/// measuring differently-shaped catalogs. That also makes the per-show counts
/// the *measured* long tail (median 12, p99 279, max 2,799) rather than a flat
/// division: a flat one would put every show wholly inside one batch and erase
/// the case the relationship cost is suspected to live in — a show whose block
/// spans batches, so a later batch fetches a `Series` that already owns
/// thousands of persisted episodes and appends to it.
struct M3UEpisodePlan {
    struct Entry {
        let show: Int32
        let season: Int16
        let number: Int16
        let streamId: Int32
    }

    let shows: [(name: String, group: String, logo: String)]
    let entries: [Entry]

    /// The measured catalog runs ~1,485,000 episodes across ~43,500 shows.
    static let episodesPerShow = 34

    static func make(episodeCount: Int) -> M3UEpisodePlan {
        var generator = SeededGenerator()
        let showCount = max(episodeCount / episodesPerShow, 1)
        let shows = PerfFixtures.providerShowDescriptors(count: showCount, using: &generator)

        var entries: [Entry] = []
        entries.reserveCapacity(episodeCount)
        var walk = ProviderEpisodeWalk(episodeCount: episodeCount, showCount: shows.count)
        while let block = walk.nextBlock(using: &generator) {
            for episode in block {
                entries.append(
                    Entry(
                        show: Int32(episode.show),
                        season: Int16(episode.season),
                        number: Int16(episode.number),
                        streamId: Int32(episode.streamId)
                    )
                )
            }
        }
        return M3UEpisodePlan(shows: shows, entries: entries)
    }

    func url(_ entry: Entry) -> String {
        PerfFixtures.providerEpisodeURL(streamId: Int(entry.streamId))
    }
}

/// Where the parent is attached to a newly built `Episode`.
enum SeriesAttachment {
    case none
    /// Through the initializer, on an instance the context does not hold yet —
    /// the pre-branch shape, kept as the other half of the delta.
    case atInit(Series)
    /// By assignment, after `context.insert` has registered the episode —
    /// what `importEpisodes` does today.
    case afterInsert(Series)

    var seriesAtInit: Series? {
        if case let .atInit(series) = self { return series }
        return nil
    }
}

/// How one batch's episodes are ordered before they are written.
enum M3UEpisodeInsertShape {
    /// File order — which `importEpisodes` still walks — with the relationship
    /// attached through the initializer, the pre-branch shape.
    case fileOrder
    /// The batch sorted by series, so each `Series` is touched in one run.
    case groupedBySeries
    /// Round-robin across the batch's shows — the pathological ungrouped case,
    /// which bounds what file order's contiguity is already worth.
    case interleavedAcrossSeries
    /// File order, but `Episode.series` is never assigned. The delta against
    /// `.fileOrder` *is* the relationship cost.
    case withoutSeriesRelationship
    /// File order, and the relationship is assigned — but on an episode that is
    /// already registered, instead of through the initializer. This is what
    /// `importEpisodes` does today; `.fileOrder` wires the inverse on a
    /// transient backing store and lets `insert` migrate it, and the two shapes
    /// differ in nothing but the order of those two statements.
    case assignSeriesAfterInsert

    var assignsRelationship: Bool {
        self != .withoutSeriesRelationship
    }

    /// How the variant attaches the parent to a freshly built `Episode`.
    func attachment(_ series: Series) -> SeriesAttachment {
        switch self {
        case .withoutSeriesRelationship: .none
        case .assignSeriesAfterInsert: .afterInsert(series)
        case .fileOrder, .groupedBySeries, .interleavedAcrossSeries: .atInit(series)
        }
    }

    /// Absolute entry indices, in the order this shape writes them.
    func order(of range: Range<Int>, plan: M3UEpisodePlan) -> [Int] {
        switch self {
        case .fileOrder, .withoutSeriesRelationship, .assignSeriesAfterInsert:
            return Array(range)
        case .groupedBySeries:
            return range.sorted { plan.entries[$0].show < plan.entries[$1].show }
        case .interleavedAcrossSeries:
            var byShow: [Int32: [Int]] = [:]
            var showOrder: [Int32] = []
            for index in range {
                let show = plan.entries[index].show
                if byShow[show] == nil { showOrder.append(show) }
                byShow[show, default: []].append(index)
            }
            var ordered: [Int] = []
            ordered.reserveCapacity(range.count)
            var cursor = 0
            while ordered.count < range.count {
                for show in showOrder where cursor < byShow[show]!.count {
                    ordered.append(byShow[show]![cursor])
                }
                cursor += 1
            }
            return ordered
        }
    }
}

// MARK: - Relationship attribution

final class M3UEpisodeRelationshipBenchmarks: XCTestCase {
    /// Matches `ContentSyncManager.batchSize`. It is a memory contract, not a
    /// throughput knob, and the point here is to reproduce the write shape.
    private let batchSize = 2000

    /// One tenth of the measured provider's 1,485,000 episodes, which also puts
    /// it alongside `M3UPersistenceBenchmarks`' 148,411 so the two are
    /// comparable. Four variants at full scale would be hours.
    private static let episodeCount = 150_000

    /// Built once for the whole suite: every variant must see byte-identical
    /// input, and regenerating it per test would put ~4 s of fixture work into
    /// each `setUp`.
    private static let plan = M3UEpisodePlan.make(episodeCount: episodeCount)

    /// Owns the two production existing-row lookups. Built per iteration but
    /// outside the measured region — its `XtreamClient` opens a `URLSession`.
    private var lookups: ContentSyncManager!

    // MARK: Variants

    /// The pre-branch shape: episodes written in file order, each constructed
    /// with `series:` set. This is the denominator every other number here is
    /// read against.
    func testInsertEpisodesInFileOrder() {
        measureInsert(shape: .fileOrder)
    }

    /// Each batch sorted by series before it is written. If the inverse fault is
    /// the cost, this is the cheap fix — and if it lands on top of file order,
    /// grouping buys nothing because a provider file is already grouped.
    func testInsertEpisodesGroupedBySeries() {
        measureInsert(shape: .groupedBySeries)
    }

    /// Round-robin across the batch's shows. Not a candidate implementation —
    /// it is the control that shows how much the file's own contiguity is
    /// already saving, and therefore the ceiling on what re-grouping could add.
    func testInsertEpisodesInterleavedAcrossSeries() {
        measureInsert(shape: .interleavedAcrossSeries)
    }

    /// Same rows, same `Series` inserts, same field application — but
    /// `Episode.series` is never assigned, so no inverse is ever faulted or
    /// appended to. `.fileOrder` minus this is the relationship's share.
    ///
    /// It is a measurement device, not a proposal: D3 keeps episode
    /// materialisation eager and the relationship declaration untouched.
    func testInsertEpisodesWithoutSeriesRelationship() {
        measureInsert(shape: .withoutSeriesRelationship)
    }

    /// File order, relationship attached, but after `context.insert` rather than
    /// in the initializer — what `importEpisodes` does today. Reordering the
    /// batch was measured to buy nothing, so this was the other in-place shape
    /// available to it: it asks whether the cost is the inverse itself or the
    /// transient-to-registered migration of an already-wired relationship.
    func testInsertEpisodesAssigningSeriesAfterInsert() {
        measureInsert(shape: .assignSeriesAfterInsert)
    }

    // MARK: Harness

    /// One iteration: a pass writes 150k episodes plus their series through a
    /// real SQLite file. Store creation and teardown stay outside the number,
    /// the same shape as `M3UPersistenceBenchmarks.measureStoreWork`.
    private func measureInsert(shape: M3UEpisodeInsertShape) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 1
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            guard let store = try? PerfStore.makeOnDiskContainer() else {
                XCTFail("could not create the on-disk store")
                return
            }
            defer { PerfStore.destroy(directory: store.directory) }
            let playlistId = UUID()
            lookups = ContentSyncManager(modelContainer: store.container)

            startMeasuring()
            insertEpisodes(shape: shape, playlistId: playlistId, container: store.container)
            stopMeasuring()

            assertCatalogWasWritten(container: store.container, shape: shape)
        }
    }

    private func insertEpisodes(shape: M3UEpisodeInsertShape, playlistId: UUID, container: ModelContainer) {
        let plan = Self.plan
        for batchStart in stride(from: 0, to: plan.entries.count, by: batchSize) {
            autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                upsert(
                    range: batchStart ..< min(batchStart + batchSize, plan.entries.count),
                    plan: plan,
                    shape: shape,
                    playlistId: playlistId,
                    context: context
                )
                if context.hasChanges { try? context.save() }
            }
        }
    }

    /// A copy of `importEpisodes`' body, minus the seen-set bookkeeping (that
    /// is `Set<UInt64>` insertion, identical across the four variants) and with
    /// the loop order supplied by `shape`.
    private func upsert(
        range: Range<Int>,
        plan: M3UEpisodePlan,
        shape: M3UEpisodeInsertShape,
        playlistId: UUID,
        context: ModelContext
    ) {
        let order = shape.order(of: range, plan: plan)
        let seriesIds = order.map { index -> String in
            let name = plan.shows[Int(plan.entries[index].show)].name
            return M3UIdentity.seriesId(playlistId: playlistId, name: name)
        }
        let episodeIds = order.enumerated().map { position, index in
            M3UIdentity.episodeId(seriesId: seriesIds[position], url: plan.url(plan.entries[index]))
        }
        let batch = BatchContext(
            playlistId: playlistId,
            order: order,
            seriesIds: seriesIds,
            episodeIds: episodeIds,
            seriesById: lookups.existingSeries(ids: seriesIds, context: context),
            episodes: lookups.existingEpisodes(ids: episodeIds, context: context)
        )

        for position in order.indices {
            let series = resolveSeries(position: position, plan: plan, batch: batch, context: context)
            upsertEpisode(
                position: position,
                plan: plan,
                batch: batch,
                attachment: shape.attachment(series),
                context: context
            )
        }
    }

    /// Per-batch state in one reference type. Threading six `inout` dictionaries
    /// through the two helpers instead would break SwiftLint's parameter count,
    /// and the lifetime is exactly one batch either way.
    private final class BatchContext {
        let playlistId: UUID
        let order: [Int]
        let seriesIds: [String]
        let episodeIds: [String]
        var seriesById: [String: Series]
        var episodes: [String: Episode]
        var seriesApplied = Set<String>()

        init(
            playlistId: UUID,
            order: [Int],
            seriesIds: [String],
            episodeIds: [String],
            seriesById: [String: Series],
            episodes: [String: Episode]
        ) {
            self.playlistId = playlistId
            self.order = order
            self.seriesIds = seriesIds
            self.episodeIds = episodeIds
            self.seriesById = seriesById
            self.episodes = episodes
        }
    }

    /// The series half of `importEpisodes`' loop: resolve or insert the parent,
    /// then apply its two m3u-owned fields once per batch. `cover` keeps
    /// consulting later entries while it is nil, exactly as production does, so
    /// an early episode without artwork does not leave the show blank.
    private func resolveSeries(
        position: Int,
        plan: M3UEpisodePlan,
        batch: BatchContext,
        context: ModelContext
    ) -> Series {
        let show = plan.shows[Int(plan.entries[batch.order[position]].show)]
        let id = batch.seriesIds[position]
        let series: Series
        if let found = batch.seriesById[id] {
            series = found
        } else {
            series = Series(id: id, seriesId: M3UIdentity.numericId(for: show.name), name: show.name)
            series.num = batch.order[position]
            context.insert(series)
            batch.seriesById[id] = series
        }
        if batch.seriesApplied.insert(id).inserted || series.cover == nil {
            let categoryId = "\(batch.playlistId.uuidString)-series-\(show.group)"
            if series.categoryId != categoryId { series.categoryId = categoryId }
            if series.cover == nil { series.cover = show.logo }
        }
        return series
    }

    /// The episode half. The attachment is `.none` only for the control variant,
    /// which is the whole point of the suite: everything else about the write is
    /// identical across variants.
    private func upsertEpisode(
        position: Int,
        plan: M3UEpisodePlan,
        batch: BatchContext,
        attachment: SeriesAttachment,
        context: ModelContext
    ) {
        let entry = plan.entries[batch.order[position]]
        let show = plan.shows[Int(entry.show)]
        let url = plan.url(entry)
        let id = batch.episodeIds[position]

        let episode: Episode
        if let found = batch.episodes[id] {
            episode = found
        } else {
            episode = Episode(
                id: id,
                episodeId: M3UIdentity.key(for: url),
                title: "",
                containerExtension: "mkv",
                seasonNum: Int(entry.season),
                episodeNum: Int(entry.number),
                series: attachment.seriesAtInit
            )
            context.insert(episode)
            if case let .afterInsert(series) = attachment { episode.series = series }
            batch.episodes[id] = episode
        }
        if episode.title != show.name { episode.title = show.name }
        if episode.directSource != url { episode.directSource = url }
        if episode.movieImage != show.logo { episode.movieImage = show.logo }
    }

    /// A silently empty write would measure a no-op and report it as a win. The
    /// relationship variant is checked too: if `series:` stopped attaching, the
    /// `.fileOrder` number would collapse into the `.withoutSeriesRelationship`
    /// one and read as a discovery.
    private func assertCatalogWasWritten(container: ModelContainer, shape: M3UEpisodeInsertShape) {
        let context = ModelContext(container)
        let episodes = (try? context.fetchCount(FetchDescriptor<Episode>())) ?? 0
        let series = (try? context.fetchCount(FetchDescriptor<Series>())) ?? 0
        XCTAssertEqual(episodes, Self.episodeCount, "episode count")
        XCTAssertGreaterThan(series, 0, "no series written")

        // Every inverse, not a sample: `.assignSeriesAfterInsert` writes the
        // relationship through a different statement than the other variants,
        // and a partially attached catalog there would read as a five-fold win.
        // Counted through `Series.episodes` rather than a `series != nil`
        // predicate — a nil test on a to-one is the SwiftData predicate shape
        // that has crashed SQL generation before. Outside the measured region.
        let allSeries = (try? context.fetch(FetchDescriptor<Series>())) ?? []
        let attached = allSeries.reduce(0) { $0 + $1.episodes.count }
        if shape.assignsRelationship {
            XCTAssertEqual(attached, Self.episodeCount, "episodes that reached their series")
        } else {
            XCTAssertEqual(attached, 0, "the control variant attached a series")
        }
    }
}
