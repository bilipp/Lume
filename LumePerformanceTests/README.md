# LumePerformanceTests

Lume's dedicated performance suite. Separate target, separate scheme, separate
build configuration — so it never slows a normal `xcodebuild test`, and so the
numbers mean something.

```bash
Scripts/run-performance-tests.sh                                  # whole suite
Scripts/run-performance-tests.sh ParsingBenchmarks                # one suite
Scripts/run-performance-tests.sh ParsingBenchmarks/testXMLTVDateParsing
```

The script builds into its own `-derivedDataPath` (`/tmp/lume-perf-dd`, override
with `LUME_PERF_DD`) and pairs it with `-clonedSourcePackagesDirPath`
(`~/Library/Developer/Lume-SharedSPM`, override with `LUME_PERF_SPM`). The pair
is not optional: a private DerivedData without a shared package clone re-clones
the whole package graph — KSPlayer's FFmpeg xcframeworks plus VLCKit's 865 MB
one, ~6.4 GB per build dir.

## Why a separate configuration

The suite builds under **Benchmark** = Release settings + `ENABLE_TESTABILITY`
(+ explicit `-O`). This matters more than anything else here: Debug is `-Onone`,
which makes the parsers several times slower than shipped code and turns every
measurement into fiction. `ENABLE_TESTABILITY` is what still allows
`@testable import Lume` against an optimized build.

`Benchmark` was added rather than reusing Release because enabling testability on
Release would change what ships. Debug, Release and Sideload are untouched.

## The layers

| Layer | Where | What it catches |
|---|---|---|
| Microbenchmarks | `ParsingBenchmarks`, `PersistenceBenchmarks`, `M3UPersistenceBenchmarks` | Parser / import regressions |
| Browse read path | `BrowseQueryBenchmarks`, `EPGQueryBenchmarks` | A browse fetch going back to scanning |
| End-to-end import | `M3UColdImportBenchmarks` | The whole production cold import, phase by phase |
| Attribution harnesses | `M3UEpisodeRelationshipBenchmarks`, `M3UExistingRowFetchBenchmarks` | Which part of an import loop the time is actually in |
| Signpost metrics | `SignpostBenchmarks` | A named production phase getting slower |
| Field telemetry | `AppPerformanceMetrics` (MetricKit) in the app | What users actually experience |
| Player QoE | `PlaybackQoE` in the app | Join time, rebuffering, startup failures |

The last two are not tests — they run in the shipping app and surface in the
diagnostic report the user can export (Settings → Diagnostics). They are listed
here because they are the same measurement programme: the tests tell you whether
a phase regressed on your machine, MetricKit and QoE tell you whether it matters
in the field.

## The browse path has two halves

Import is not the only thing users wait on. A 284k-row catalog made every browse
interaction expensive too — 1,904 ms of SQL on a cold launch, 739 ms on a tab
switch, 1,158 ms on a single "Add to Favorites" — and none of it was covered
here, because every other file in this target measures the sync path.

`BrowseQueryBenchmarks` covers the fetches behind the Movies/Series rails, the
Live TV section gates, a category preview row and search. What makes those
regress is unusual, and worth knowing before reading the numbers: they are
one-token changes that alter **no visible row**. A `sortBy:` added back to a
bounded fetch, a dropped `fetchLimit`, `comparator: .lexical` lost to the
`SortDescriptor` default. The app still shows exactly the right content — after
scanning the whole table — so the change passes review, the unit suite and every
screenshot.

That shape needs a second, cheaper guard, because a benchmark only catches it if
somebody runs the benchmark. `LumeTests/Services/BrowseQueryShapeTests.swift`
asserts the contracts themselves — the limit is set, the probe has no sort, the
scope is in the predicate, the comparator is lexical — and runs in the normal
suite on every commit. Both halves were mutation-tested when they were written:
removing `fetchLimit = 1` from the Live TV probe moved its benchmark
0.004 s → 0.140 s *and* failed the shape test.

Two benchmarks are deliberately a matched pair. `testSearchCommonTerm` and
`testSearchRareTerm` measure the same fetch against a dense and a sparse term:
without an ORDER BY, SQLite stops the scan at the 50th hit, so the common term is
several times *faster* than the rare one. If they ever converge, a `sortBy:` has
come back.

## Signposts are the load-bearing part

`Lume/Services/Diagnostics/PerformanceSignposts.swift` names every phase we have
ever had to profile by hand. One `Perf.begin`/`Perf.end` pair buys three things:

1. A Points of Interest lane in Instruments (phase boundaries, not just stacks).
2. `XCTOSSignpostMetric` measurements of *production* code, by name.
3. `os_log`-based timing in the field, via the debug log exporter.

The names in `PerfSignpost` are a contract with `SignpostBenchmarks` — rename one
and its benchmark fails with "no samples" rather than silently measuring nothing.
`testSignpostNamesAreUnique` guards against two phases colliding on one name.

## Fixtures are generated, never committed

`PerfSupport.swift` writes the m3u playlists, XMLTV guides and Xtream JSON each
run, from a fixed-seed LCG. A 600k-entry playlist is ~60 MB; the repo carries the
generator instead (same reasoning as the gitignored `ExampleData/`). Fixed seed
matters: a fixture that changed between runs would be indistinguishable from a
regression.

Sizes are a compromise between representativeness and a suite that finishes in a
few minutes. When chasing a specific regression, raise `entryCount` locally —
don't commit the raise, or every future baseline shifts.

## Stores are on disk, not in memory

`PerfStore.makeOnDiskContainer()` creates a real store file per iteration. An
in-memory `ModelContainer` skips SQLite entirely, so it understates import cost
by roughly an order of magnitude — and import is the phase users wait minutes on.
(It also hides SQL-generation behaviour outright; a predicate crash we once
shipped only reproduced on-disk.)

Every configuration sets `cloudKitDatabase: .none`, without exception: the
catalog's `@Attribute(.unique)` models crash container load when CloudKit
mirroring is left at `.automatic` on an entitled host.

## What the import actually costs

The sync-performance work targeted one real provider: 56,713 live channels,
178,007 movies and 47,568 series — 282,288 rows and ~135 MB of JSON per sync,
which took ~4 minutes on an Apple TV 4K. Everything below was measured against
that shape. Absolute seconds are from an iPhone 17 Pro simulator under the
Benchmark configuration; the ratios are the portable part.

**`context.save()` is ~90% of it — on the Xtream path.** Decode, object
construction and the upsert lookup share the remaining tenth. That figure was
measured on the 282,288-row Xtream catalog described above, whose rows are
47,568 series *shells* and no episodes at all, and it was never re-attributed to
anything else. It does **not** describe the m3u cold path, where 86% of the
entries are episodes: there, the largest single item turned out to be neither a
`save()` nor a fetch but the `Episode` → `Series` relationship being wired
through the initializer — 83% of episode-insert time, and 64% of the whole
import (see *The m3u cold path, measured end to end* below). Read the 90% as
what it is: the Xtream refresh's shape.

### Levers that were measured and are dead

Each of these moved import cost by **under 6%** — under the run-to-run noise of a
warm laptop. Recorded so nobody spends another day on them:

| Lever | Result | Re-measured since |
|---|---|---|
| `batchSize` 500 / 2,000 / 10,000 / 50,000 | all within noise | no |
| Dropping all 11 `#Index` groups on `Movie` | 61.1 s → 60.9 s | no |
| Removing `@Attribute(.unique)` | 15.98 s → 15.83 s | no |
| Removing the per-batch existing-row lookup | 62.8 s → 62.6 s | **yes** — still cheap at 1.5M rows, see below |
| One shared context instead of a fresh one per batch | 19.68 s → 19.01 s | no |

**Read that table with two caveats.** It was measured on a standalone 178k-row
harness that is *not in the repo* and cannot be re-run, so the seconds are
internally comparable and line up with nothing else here. And it was measured on
a movie-shaped catalog: index maintenance on bulk insert is superlinear in table
size, so "6% at 178k rows" does not automatically transfer to the 1.5M-row
`Episode` table an m3u cold import builds. Treat every row without a *yes* in the
last column as **unverified for the episode-dominated cold path** — not wrong,
just never checked there.

The one row that was re-checked is the per-batch existing-row lookup, because
`importEpisodes` runs two `IN`-clause fetches of up to 2,000 ids each against
tables that grow to 1.5M rows. `M3UExistingRowFetchBenchmarks` times a single
such fetch on a fresh `ModelContext`, mean of 20:

| `Episode` rows in the table | 150k | 500k | 1.5M |
|---|---|---|---|
| Episodes, contiguous ids (the production shape) | 43.41 ms | 42.46 ms | 42.29 ms |
| Episodes, ids spread across the table | 51.39 ms | 60.13 ms | 70.18 ms |
| Series, deduped to ~60 ids | 3.61 ms | 3.74 ms | 3.76 ms |

A real batch is 2,000 consecutive file entries, so the contiguous row is what
production pays and it is **flat** — the unique index absorbs the extra tree
depth, and only the spread control grows (+37% over 10× the rows). What that
scan pays for is page locality, not table size. At ~46 ms per batch and 743
batches both lookups together are ~34 s of a full-file import, which keeps the
original "under 6%" verdict at provider scale — and that is an upper bound,
since a cold import's fetches match nothing and so never materialise the 2,000
rows these numbers include. **Do not remove the lookup** regardless of what it
costs: `@Attribute(.unique)` turns a duplicate insert into a full-row UPSERT
that resets `isFavorite` / `watchProgress` / enrichment (the bug fixed in
f12b4b1), and an m3u file repeats stream URLs.

`batchSize` stays at 2,000 as a **memory** contract, not a throughput one — which
is why `PersistenceBenchmarks` reproduces the per-batch context shape deliberately
rather than inserting in one pass.

`propertiesToFetch = [\.id]` is the other trap. It is used correctly elsewhere in
the repo (`PlaylistDeletion.swift`, `EPGSyncManager.swift`, `GenreBrowse.swift`),
but on the prune sweep's fetch it made **both** metrics worse: 13.5 s / 1,535 MB
peak against 10.6 s / 1,224 MB for the plain fetch. Partial materialisation costs
more than it saves when the following code faults the row in anyway.

`fetchLimit` + `fetchOffset` paging on the prune sweep is the most expensive trap
of the three, because it looks like the obvious fix and it half works. It does cut
memory — 746 MB down to 281 MB — but the store still walks every row an offset
skips, so the clock went **9.28 s to 99.11 s, 10.7x worse than the unbounded fetch
it replaced**. The sweep ships with keyset paging instead (`id > cursor`, sorted by
`id`, `fetchLimit` only, cursor carried from the last row of the previous page).
Keyset paging is also what makes deleting while paging sound: every deleted row
sorts at or before the cursor, so it can never displace a row a later page has yet
to see.

### Levers that did work

Dirty-checked field application (`ContentSyncManager+Helpers`, so an unchanged row
leaves the context clean and the per-batch `save()` is skipped) and a paged prune
sweep (`ContentSyncManager+Prune`, keyset paging instead of materialising the
whole catalog). Both columns are `PersistenceBenchmarks` on the
same machine, back to back, so they are comparable to each other and to nothing
else:

| Benchmark | Before | After |
|---|---|---|
| `testImportFullXtreamCatalog` (cold, 282,288 rows) | 64.30 s | 65.54 s |
| `testReimportFullXtreamCatalogUnchanged` | 58.03 s | **14.50 s** |
| `testReimport20kUnchangedMovies` | 4.59 s | **1.09 s** |
| `testPruneFullVODCatalogWithNoDeletions`, clock | 9.35 s | **2.13 s** |
| `testPruneFullVODCatalogWithNoDeletions`, peak RSS | 843 MB avg | **274 MB avg** |
| `testInsert20kMoviesOnDisk` | 4.73 s | 4.87 s |
| `testInsert20kSeriesOnDisk` | 4.64 s | 4.75 s |
| `testInsert20kLiveStreamsOnDisk` | 2.28 s | 2.34 s |

One caveat on the re-import rows, because it is easy to over-read them. The
`insertMovies` / `insertSeries` / `insertLiveStreams` helpers in
`PersistenceBenchmarks` are hand-written copies of the sync's upsert loop — they
cannot call `syncMovies`, which is network-driven — and they were given the same
per-field guards and `hasChanges` gate in the same change. So the table measures
the *shape* of the fix, on both sides, rather than production code directly. What
pins the production path is `ContentSyncFieldApplicationTests`: an unchanged
payload leaves `context.hasChanges` false, so the `save()` is skipped. If you
change `apply*Fields`, change these helpers to match or the benchmark stops
tracking reality.

A first-ever import is allowed to stay expensive — writing 282k rows means
writing 282k rows, and on an Apple TV that is still minutes. The **refresh** path
is the one that had to get dramatically cheaper, because it is the one users hit
on every scheduled sync.

A cold import is unchanged, and the per-kind 20k inserts are ~2-3% slower — the
dirty check costs a comparison per field on rows that are all new anyway. That is
the trade, and it is the right one: every scheduled sync after the first is the
refresh case.

The prune sweep's before-numbers are worth staring at: 9.35 s to delete
**nothing**, purely to establish that no row had gone away. Its cost was never
the deletes; it was materialising every row — which is also why its peak
footprint was unstable, swinging 334 / 981 / 1,215 MB across three iterations
depending on how much of the catalog SQLite had already cached. The paged sweep
is flat at 274 MB on all three. A rewrite that had only moved wall clock would
not have fixed the jetsam hazard on an Apple TV, which is why the benchmark
measures memory alongside clock.

### The m3u pipeline writes an order of magnitude more rows

The same account, fetched as an m3u file instead of over the Xtream API: 520 MB
and 1,719,199 entries — 56,858 live, 178,231 movies and 1,484,110 episodes across
~47.4k series — against 135 MB and 282,288 rows. The difference is not the
provider; it is the shape. Xtream sends 47,568 series *shells* and Lume fetches
episodes per series on demand, while an m3u file names every episode inline and
the import materialises all of them.

The per-series distribution is what any fixture has to reproduce: 1,544 distinct
group titles, a median show of 12 episodes, p99 279, and a largest show of 2,799.
A fixture of uniformly sized shows measures neither the tail nor the per-series
work that the tail is made of.

`M3UPersistenceBenchmarks` is the store side of that: `testImportFullM3UCatalog`,
`testReimportFullM3UCatalogUnchanged` and `testPruneFullEpisodeCatalogWithNoDeletions`,
at one tenth of the file's row counts with the kind mix (3% live / 11% movie /
86% episode) preserved. A tenth, because 1.72M rows per iteration is tens of
minutes; the mix, because episodes are the kind the sync spends its time on and
were previously not benchmarked at all. It is a separate file from
`PersistenceBenchmarks` only because that one is already at SwiftLint's file and
type-body limits.

The same caveat applies as to the Xtream re-import rows above, and harder. The
`insertLiveStreams` / `insertMovies` / `insertEpisodes` helpers in
`M3UPersistenceBenchmarks` are hand-written copies of `importLive` /
`importMovies` / `importEpisodes` — they cannot call them, since those are driven
by a streaming parse of a downloaded file — and their four field appliers are
copies of `applyM3ULiveStreamFields` / `applyM3UMovieFields` /
`applyM3USeriesFields` / `applyM3UEpisodeFields` in
`Lume/Services/Sync/ContentSyncManager+M3UFields.swift`, down to `num` being
assigned only on insert and the per-series hoist of the group title. **Edit them
in lockstep.** A field added to a production applier and not here leaves the
benchmark measuring a write the app no longer performs; a guard dropped there and
not here leaves it measuring a dirty check the app no longer has. What pins the
production path is `M3UFieldApplicationTests` and
`M3USeriesFieldApplicationTests`, not this benchmark.

That is not a hypothetical. `importEpisodes` moved its `episode.series`
assignment out of the `Episode` initializer to after `context.insert`, and until
the copy here was moved with it this benchmark was measuring an insert shape the
app no longer performs — one that costs ~5× the clock and ~7× the peak
footprint. The copies are back in lockstep as of that change; the numbers in the
table below are from after it.

`M3UColdImportBenchmarks` now covers the same store work through the *real*
`ContentSyncManager`, which raises the fair question of whether these
hand-written copies still earn their place. They do, for one reason: they are
the only isolated **re-import** measurement on the m3u path
(`testReimportFullM3UCatalogUnchanged`), and the cold suite's 600k import is ~3
minutes per pass against this file's seconds. Keep them for the re-import and
prune rows; reach for the cold suite for anything about a first import.

iPhone 17 Pro simulator, Benchmark configuration — one machine, one sitting, so
each column is comparable to itself and to nothing else. The *first* column is
the original PR #202 run; the *now* column is after the cold-import work on this
branch, which changed the model (`similarTMDBIds` optional) and this file (the
`episode.series` lockstep fix), so the movement is not attributable to any one
of them:

| Benchmark | Clock (then → now) | Peak RSS (then → now) |
|---|---|---|
| `testImportFullM3UCatalog` (cold, ~177k rows) | 27.02 s → 25.99 s | 248 MB → **67.5 MB** |
| `testReimportFullM3UCatalogUnchanged` | **5.21 s** → 5.75 s | 242 MB → **61.0 MB** |
| `testPruneFullEpisodeCatalogWithNoDeletions` | 0.75 s → 0.81 s | 243 MB → **62.7 MB** |

The clock is flat here while the cold-import suite's episode loop fell 5×, and
that is informative rather than contradictory: this fixture divides its ~148k
episodes evenly over 4,740 shows (~31 each), so no `Series.episodes` inverse
ever holds more than a few dozen members. The real file's tail runs to 2,799,
and the relationship cost scales with how big the inverse array gets — which is
why the shape of the fixture, not just its row count, is what
`M3UColdImportBenchmarks` and `M3UEpisodeRelationshipBenchmarks` were built to
get right.

The re-import is ~5x cheaper than the cold pass, which is the dirty check and the
`hasChanges` gate doing on the m3u path what they already do on the Xtream one.

The prune test drives the production `pruneStaleM3UEpisodes` directly rather than
the guarded `pruneEpisodes` wrapper, so it measures the sweep and not the
coverage gate in front of it — and does not write a skip counter into
`UserDefaults` as a side effect. Its seen-set is the `Set<UInt64>` of
`M3UIdentity.hash64` the import actually builds; the id set it replaced cost
+337 MB resident, held live across the whole import and all four sweeps.

Neither benchmark is where an episode regression gets caught in a normal test
run, though. That is `M3USyncTests`, in `LumeTests`: alongside the 100k
live-and-movie playlist it now syncs an episode-only playlist of ~3,000 shows
with uneven per-show counts end to end through the real `ContentSyncManager`,
under the same bounded-time assertion. The old scale test had zero episodes in
it, so the path that is 86% of a real file was the one path with no scale
coverage at all.

### The m3u import's other half is not SwiftData

On the Xtream side `save()` is ~90% of the import. The m3u side has a second half
that is pure CPU and resident memory, and it was bigger than anything SwiftData
was doing per row. All three numbers are against the real 520 MB / 1,719,199-entry
file:

| Cost | Before | After |
|---|---|---|
| Season/episode regex, per import | ~75 s | ~21x cheaper |
| The four seen-id registries, resident | +337 MB | ~19–33 MB |
| `M3UParser` peak RSS | 502 MB | 10 MB |

**The regex was compiled 1,719,199 times, and then again 1,484,110 times.**
`M3UClassifier.episodeInfo` declared its pattern as a literal inside the function
and matched with `name.range(of:options: .regularExpression)`, which builds an ICU
matcher per call — ~40 s over the file. Then
`ContentSyncManager.cleanEpisodeTitle` ran the *identical* pattern a second time
over every one of the ~1.48M names `classify` had just matched, only to derive the
episode title: another ~35 s. Roughly 75 s of CPU burned before a single row is
written. The fix is a hoisted `NSRegularExpression` built once, plus threading the
match range out of `episodeInfo` so the title comes from the match that already
happened. Same ICU engine, same pattern, same first-match semantics — a
differential over all 1,719,199 real names found **0** mismatches. Do not
"improve" it into a hand-rolled UTF-8 scanner: ICU's `\b` is Unicode-aware where
an ASCII scanner's is not, and provider names in this file are dense with
superscript decoration (`ᵁᴴᴰ ³⁸⁴⁰ᴾ`). `cleanEpisodeTitle` itself is unchanged —
Xtream and Stalker still call it.

**The seen-id registries were 337 MB of `String`.** The four `Set<String>` in
`M3UImportState` are built during the import and read by the sweeps, so they were
held live across the whole run *and* all four sweeps; `seenEpisodeIds` alone was
~292 MB, because a 78-character id is past Swift's 15-byte small-string form and
so is a separate heap allocation per entry. They are now `Set<UInt64>` of
`M3UIdentity.hash64` (FNV-1a 64, deterministic across launches — never `Hasher`,
whose seed changes per process), and each set is released the moment its own sweep
returns. At 1.48M keys the collision probability is ~6e-8 and the direction is
benign: a collision makes the sweep *keep* a stale row, never delete a live one.

**The parser's chunk loop had no `autoreleasepool`.** `String(bytes:encoding:)`,
`trimmingCharacters` and `Data.subdata`/`split` all autorelease per line, and
`importM3UFile` was then one uninterrupted synchronous stretch inside an actor
job with no suspension point, so the enclosing pool never drained until the whole
file was done: 502 MB peak RSS against 10 MB with a pool around the loop body.
The import has since been split into a producer task and a consumer on the actor
(`ContentSyncManager+M3UStream.swift`), which is why each side now carries its
**own** pool — one pool on one side would drain neither the other's.
`ParsingBenchmarks.testM3UParse120kEntries` cannot see this — 120k entries is only
~35 MB, well under where it hurts — which is why the number above is from the real
file and not from the suite.

Attribution for all of this comes from the sub-phase signposts added alongside it
(`M3UParse`, `M3UClassify`, `M3UUpsertLive`/`Movies`/`Episodes`, and one per
sweep), nested inside the existing `M3UImport` boundary so older traces and
baselines still resolve. Before them the m3u import was a single opaque number and
none of the above could have been ranked.

### The m3u cold path, measured end to end

`M3UColdImportBenchmarks` is the first benchmark that drives the *production*
cold import: it seeds a real `Playlist` whose `m3uURL` is a `file://` URL and
calls `ContentSyncManager.syncPlaylist`, so the number covers the download stub,
the streaming parse, classification, `ensureCategories`, `seedInsertOrder`, the
three upsert loops, all five prune sweeps and the history purge — everything a
user waits on except the network. `M3UPersistenceBenchmarks` measures the store
work through hand-written copies and skips all the rest of that.

- **Fixture.** `PerfFixtures.writeM3UProviderShape`, which bakes in the measured
  provider mix (3% live / 11% movie / 86% episode) and the per-series long tail
  (median 12, p99 279, max 2,799) with each show's episodes contiguous. The flat
  `writeM3U` would miss the tail the episode cost is made of.
- **Scale.** One constant, `entryCount`, at **600,000** — the real provider file
  is 1,729,847. Raise that constant and nothing else to measure closer to full
  scale (`showCount` is derived from it); a pass costs roughly linearly in it.
  Don't commit a raise, or every future comparison shifts.
- **Store.** `PerfStore.makeOnDiskContainer()`, destroyed per iteration. The
  fixture is written once in `setUp` — 600k entries is ~180 MB and takes real
  time — and both `M3UDigestStore` and `SweepSkipDefaults` are cleared around
  every iteration, or the second pass measures `m3uImportIsRedundant` returning
  early and reports a no-op as a win.
- **Both metrics in one pass.** `XCTClockMetric` *and* `XCTMemoryMetric`
  together: peak RSS is the Apple TV jetsam contract (no swap — a jetsammed sync
  reads as "the sync never finishes"), and it has moved independently of the
  clock more than once on this branch. Measuring them in separate passes would
  double a ~3-minute import for no extra information.
- **Every signpost in the same pass, too.** All twelve names — the eleven
  `M3U*` ones plus `CatalogPurgeHistory` — go into the same `metrics:` array. One test per signpost would mean one full 600k import
  per signpost.

**`.m3uParse` is emitted once per *gap between batches*** — the parse and the
write interleave, so it brackets the parser's turn, ~301 intervals at 600k
entries and ~860 on the real file. A check that expects a single interval finds
none. The same is true of `.m3uClassify` and the three `.m3uUpsert*`, which are
per batch. `XCTOSSignpostMetric` keeps **one value per name per iteration** and
that value is the *first* interval, not their sum, so read those five as a
first-batch sample and not as a phase total. `.m3uImport`, the five sweeps and
`.catalogPurgeHistory` are one interval each and are exact. The purge is
emitted from `performSync` for every source, so it sits beside `.m3uImport`
rather than inside it.

`SignpostBenchmarks.testM3UImportSignposts` drives the same twelve names over a
400-entry playlist. It is a tripwire, not a number: a renamed or dropped
signpost otherwise turns this suite's per-phase split into silence rather than
into a failure.

#### Baseline vs final

The m3u cold-import work, measured on this suite from end to end. iPhone 17 Pro
simulator (iOS 26.4), Benchmark configuration, 600,000 entries / 15,000 shows —
which the import resolves to 18,000 live, 66,000 movies and 516,000 episodes.
One machine, one sitting; comparable to each other and to nothing else.

| Stage | Clock | Peak RSS |
|---|---|---|
| Baseline (branch point) | 571.5 s | 1,120,276 kB |
| `similarTMDBIds` optional on `Movie`/`Series` | 553.8 s | 1,082,314 kB |
| Post-import persistent-history purge | 555.3 s | 1,140,232 kB |
| `episode.series` assigned after `context.insert` | **200.2 s** | **173,214 kB** |
| Bounded producer/consumer + classification off the writer | 188.3 s | 169,757 kB |
| Final confirmation run | 191.9 s | 154,930 kB |
| Re-run after the quality/simplify pass | 208.5 s | 194,972 kB |
| **Total** | **571.5 s → 208.5 s (−63.5%, 2.7×)** | **1,094 MB → 190 MB (−83%, 5.7×)** |

Rows four through six are, for the measured path, the same code; the spread
between them (+1.9% then +8.6% on the clock, −8.7% then +25.8% on peak) is
wider than one sitting's noise and is worth naming rather than averaging away.
Two candidate explanations, neither separated by a single iteration each: the
simplify pass did touch this path (the `similarTitleIds` accessor, the shared
`PerfSupport` sync harness, the purge moving to `performSync`), and the machine
had been building and testing continuously for ~8 hours by the last run — this
file's own rule is that "a laptop that just finished a full build is 20–30%
slower than a cold one", which covers a +8.6% clock on its own but not a +26%
peak. Treat 208.5 s / 190 MB as the honest current figure and 191.9 s / 155 MB
as the best seen; re-measure both on a cold machine with `iterationCount` > 1
before crediting or blaming the simplify pass.

Where the 191.9 s goes, from the same pass:

| Phase | Seconds | Notes |
|---|---|---|
| `M3UImport` | 194.889 | one interval, the whole import |
| ├ batch loop | ~130.0 | parse + classify + `ensureCategories` + the three upserts |
| └ sweeps + purge | 64.923 | 33% of the import |
| `M3UPruneEpisodes` | 58.301 | the single most expensive named phase now |
| `M3UPruneMovies` | 4.456 | |
| `M3UPruneSeries` | 0.730 | |
| `M3UPruneLive` | 0.542 | |
| `M3UPruneCategories` | 0.038 | |
| `CatalogPurgeHistory` | 0.856 | measured while it still ran inside `M3UImport` |
| `M3UParse` | 0.019 | **first inter-batch gap only** — ~301 of them, so ~6 s scaled |
| `M3UClassify` | 0.021 | first batch only; ~6 s scaled |
| `M3UUpsertLive` | 0.036 | first batch (2,000 live rows) |
| `M3UUpsertMovies` / `M3UUpsertEpisodes` | ~0 | this fixture emits all live entries first, so batch 1 has neither |

Splitting the three upsert loops against each other needs an Instruments Points
of Interest trace; `XCTOSSignpostMetric` cannot, by construction (see the
`.m3uParse` note above). What the batch loop is made of was answered instead by
`M3UEpisodeRelationshipBenchmarks`, and that answer is the whole table above:
104.7 s of a 126.3 s isolated episode loop was the relationship wiring alone.

**Which levers actually moved the number.** One did almost all of it — moving
`episode.series` after `context.insert`, worth −355 s and −967 MB, because
building an `Episode` with `series:` set leaves an unregistered instance holding
a relationship that `insert` then has to migrate out of the transient backing
store. Taking classification off the writer was worth −12 s. Making
`similarTMDBIds` optional was worth −18 s and −38 MB, all of it archiver
round-trips on never-enriched rows. The history purge is not a throughput lever
at all and was never expected to be: SwiftData records history unconditionally,
so the purge only gives the pages back afterwards (~34 bytes per catalog row,
~58 MB on the real file) for 0.86 s.

**The `similarTMDBIds` row is not a migration event.** Every figure above comes
from a store the suite created from scratch, so the optionality change was
checked separately against a real `default.store` written by the *pre-change*
schema (67 `Movie` and 23 `Series` rows, 58 of the movies holding the 219-byte
archived empty array). Opened under the current schema it needs no migration at
all: Core Data's `NSStoreModelVersionHashes` entry for `Movie` is byte-identical
before and after — an attribute's optionality is not part of its version hash —
and all 67 rows read back non-`nil`, i.e. legacy rows are `Optional([])` and
only freshly imported ones are `nil`. Worth re-checking the same way after any
further catalog attribute change, because the catalog container has no
`VersionedSchema`/`MigrationPlan` and a load failure is a launch-time
`fatalError` outside `DEBUG`: copy a pre-change `default.store` out of the
simulator container and open it with the current schema.

**Two things in this programme have no number, deliberately.** `ImportPacing`
adds exactly zero delay at `.nominal` with Low Power Mode off, which is the only
state a simulator ever reports, so it cannot move a benchmark and is pinned by
stubbed unit tests instead. And 5a — the bounded producer/consumer channel — was
never measured on its own; it shipped as the structural half of the pair whose
combined effect is the −12 s row.

**What is left on the table.** `M3UPruneEpisodes` is now a third of the import
and has had no attention on this branch: it walks 516k rows with keyset paging
purely to establish that nothing went away. Skipping it on a genuinely first
import is the obvious idea and it is *not* free — an empty `lastSyncDate` does
not prove an empty store, because a cancelled import commits the batches it
finished, so the cheap test for "cold" is the one thing that has to be got right
before the sweep can be skipped. Below that, the parse and classification are
~12 s combined and the writer is the critical path by ~5×, which is why fanning
classification across cores measured *slower* (see `M3UBatchClassifier`). And
the file itself is the reason any of this is minutes: 600k entries here against
1,729,847 in the real thing, so multiply by ~2.9 for the shape of a real cold
import — and by an unknown factor again for a phone's NAND and thermals, which
this suite cannot see.

### `num` is insert-only, and that is what makes the dirty check pay

Xtream's `num` is a value the provider sends. m3u has no such field, so `num` is
the entry's **position in the file** — which means the obvious implementation
(assign it every sync, like every other field) hands the dirty check nothing:
one line inserted near the top of a 1.7M-entry file shifts every position after
it, so every row downstream is genuinely modified and the whole tail is rewritten.
The lever would benchmark beautifully on a byte-identical file and deliver
approximately zero against a provider that ever reorders.

So `num` is assigned **only on insert**, and only from a counter seeded one past
the highest `num` the playlist already stores (`seedInsertOrder`, three
`fetchLimit: 1` reads per import — `num` has no `#Index`, so each is a
filter-then-sort, which is tens of milliseconds against an import measured in
minutes and not worth an index every write would pay for). Two things about that
are easy to get wrong:

- Seeding matters as much as the insert-only rule. Handing an insert the raw file
  position instead *collides* — a channel prepended to the file takes `num` 0
  while the row that already holds `num` 0 keeps it, and `SortOption.playlist`
  breaks the tie arbitrarily. Uniqueness is pinned by tests in
  `M3UFieldApplicationTests`.
- The accepted cost is that new content sorts at the **end** rather than at its
  file position, so "Playlist order" drifts from the provider's file over a
  playlist's life. That is deliberate, not a bug to fix back. On a first import
  the seed is 0 and the result is exactly the file order.

### Dead levers, m3u edition

The Xtream dead levers above all still apply — the m3u path uses the same store,
the same batch shape and the same sweep. These are the ones specific to m3u.
Recorded so nobody re-derives them:

| Lever | Result |
|---|---|
| Reorder `M3UClassifier.classify` to test URL shape before `episodeInfo` | Wrong **and** slower |
| Fetch the `type=m3u` URL variant instead of `m3u_plus` | Loses metadata the app needs |
| Anything at the HTTP layer | The server offers no hook (see below) |

The reorder is the tempting one, because `episodeInfo` runs a regex on every
entry and the URL test is a substring scan. It is wrong twice over: the
`/series/` branch returns `.movie`, so ~1.48M episodes would import as movies —
and it measured *slightly slower* anyway. Leave `classify`'s test order alone.

`M3UClient.normalizedPlaylistURL` rewrites `type=m3u` to `m3u_plus` deliberately:
the plain variant drops `tvg-logo`, `tvg-id` and `group-title`, which are
artwork, EPG matching and categories respectively. A smaller file that imports
into a worse catalog is not a saving.

### Eager `Episode` materialisation is deferred, not decided

The m3u import writes all ~1.48M `Episode` rows up front. Xtream does not: it
stores 47,568 series shells and fetches a series' episodes on demand. Converting
m3u to the same lazy shape is the single largest remaining lever and it is
**deliberately not part of this work**.

It stayed deferred, but it is no longer the open question it was. The
relationship cost that made it look like the only remaining lever has been
isolated (`M3UEpisodeRelationshipBenchmarks`) and then removed in place: wiring
`Episode.series` through the initializer was 83% of episode-insert time, and
assigning it one statement later — after `context.insert` — took the isolated
loop from 125.53 s / 557 MB to 25.10 s / 74 MB, within 3.5 s of never assigning
the relationship at all. Eager materialisation now costs roughly what writing
the rows costs. The lazy shape would still save the writes themselves, so it
remains the largest theoretical lever, but it is no longer buying back a hidden
5×.

It is also the shape behind closed issue #45's `PersistentIdentifier … remapped
to a temporary identifier` fatal error, so the question was never only "how
slow" but "how safe".

What makes it a separate decision rather than an optimisation: Continue Watching,
Up Next, `NextEpisodeResolver`, offline episode browsing, episode search,
Downloads and Trakt's `applyPending` all read local `Episode` rows, and existing
m3u users have CloudKit watch progress keyed by episode id. Going lazy is a data
migration with a user-visible blast radius, not a change to an import loop.
Measure first.

### The provider gives you nothing to cache against

nginx/1.24.0, HTTP/1.1, `max_connections: 1`:

- **No compression.** `Accept-Encoding: gzip, deflate, br` comes back `identity`;
  the full ~135 MB crosses the wire raw.
- **No `ETag`, no `Last-Modified`, no `Cache-Control`.** Conditional GET is
  unavailable, so there is no HTTP-level way to learn that a catalog is unchanged
  — the client must download it and diff. That is why the refresh path is
  optimised around cheap *writes* rather than a cheap fetch.
- One connection means the three content fetches are serialized whether or not
  the code chooses to serialize them.

The m3u endpoint on the same host is worse, and it is where the whole 520 MB
arrives in one response. Probed directly:

- **No compression**, despite `Accept-Encoding: gzip, deflate, br`.
- **No `ETag`, no `Last-Modified`.** Nothing to make a conditional GET out of.
- **No `Content-Length`** — it is `Transfer-Encoding: chunked`, so a connection
  cut mid-file is indistinguishable from a complete short playlist. That is why
  the m3u sweeps now run behind the same coverage gate as the Xtream ones: a
  truncated download used to pass the old `totalImported > 0` check and sweep
  away everything the cut had removed.
- **No `Accept-Ranges`** — a `Range` request is answered `200` with the whole
  file, so resume is not available either.
- **37 s to first byte**, then 2m04s wall for the full download on a fast Mac.

**The download is irreducible.** Every HTTP-layer idea is dead against this
server; do not spend another afternoon on one. The only lever that works is
above the protocol: hash the downloaded file (SHA-256 over 520 MB costs 0.28 s)
and skip the import and the sweeps when the digest matches the last successful
import's. The digest is device-local in `UserDefaults`, never on a `@Model` and
never mirrored to `SyncedPlaylist` — one device's successful import must not
suppress another device's first one.

That lever is only worth anything if the provider actually returns stable bytes,
so it was checked rather than assumed: two full downloads **30 minutes apart**
came back byte-identical — same 520,540,228 bytes, same SHA-256
(`75622b6b399d9268…`). That also confirms the export is not shuffled per
request, which is the premise the insert-only `num` depends on. Note the limit
of the measurement: 30 minutes is not 24 hours, so it says the response is
deterministic, **not** that this catalog is stable across a day. If the digest
never matches in the field, that is the assumption that broke.

Worth knowing when reading any m3u number here: this provider's *same account*
exposes an Xtream API that returns the equivalent catalog in ~135 MB and 282,288
rows, against 520 MB and 1,719,199. The pipelines have different content
identity — m3u hashes the stream URL, Xtream uses provider stream ids — so
switching is not a conversion anyone can do silently without orphaning every
favourite, watch position and enrichment. The app therefore only *hints*: when an
entered m3u URL is an Xtream `get.php` endpoint carrying credentials, the
add-playlist screen says so and leaves the choice to the user.

## Baselines

Xcode stores accepted baselines in
`Lume.xcodeproj/xcshareddata/xcbaselines/…` keyed by **device model and
configuration**. To record them:

1. Open the `LumePerformance` scheme in Xcode and run the suite.
2. In the test report, click the grey diamond next to a measurement → *Accept*.
3. Commit the resulting `.xcbaseline`.

They can't meaningfully be hand-written — the key includes a hardware hash — so
this step is manual and per-machine by design.

### What baselines are and aren't good for

Only compare runs from the **same machine, same thermal state, nothing else
building**. A laptop that just finished a full build is 20–30% slower than a cold
one. That is why there is no CI gate wired up here: gating pull requests on
absolute wall clock from a shared runner produces noise, not signal.

Two ways to get a real gate, when it's wanted:

- Pin one physical device to a self-hosted runner and compare against a baseline
  recorded on that device.
- Compare machine-independent counters (allocation counts, object counts) rather
  than time.

Until then, treat the suite as a *tool you run when you touch a hot path* and as
the place a suspected regression gets confirmed or dismissed.

## Tracing a real Apple TV

`Scripts/run-performance-tests.sh` cannot answer device questions. It is
iOS-Simulator-only by construction — it resolves an iOS 26.4+ *iPhone* simulator
and refuses to run without one — and `LumePerformanceTests` excludes
`appletvos` from `SUPPORTED_PLATFORMS` outright. The 4-minute sync that started
the performance work only reproduces on the device, so it gets a manual
`xctrace` recipe.

### 1. Install a Benchmark build

Select the **LumePerformance** scheme in Xcode and Run against the Apple TV: its
build, run and test actions all pin the Benchmark configuration. Never trace a
Debug build — `-Onone` makes the import and parser numbers fiction, which is the
entire reason that configuration exists. From the command line:

```bash
xcrun xctrace list devices                       # find the Apple TV UDID
xcodebuild -project Lume.xcodeproj -scheme LumePerformance \
  -destination 'platform=tvOS,id=<APPLE_TV_UDID>' build
```

### 2. Record the sync phases

`Perf` posts to an `OSSignposter` whose **subsystem is the app's bundle
identifier** (`com.bilipp.lume`) and whose **category is `Performance`**. That
feeds Instruments' Points of Interest lane, so the trace shows the sync phases
as intervals rather than an undifferentiated wall of stacks — for an Xtream
playlist `SyncMovies` / `XtreamFetchMovies` / `XtreamDecodeMovies` /
`UpsertMovies` / `PruneMovies`, and for an m3u one the twelve `M3UDownload` /
`M3UImport` / `M3UParse` / `M3UClassify` / `M3UUpsertLive` / `M3UUpsertMovies` /
`M3UUpsertEpisodes` / `M3UPruneLive` / `M3UPruneMovies` / `M3UPruneEpisodes` /
`M3UPruneSeries` / `M3UPruneCategories`, plus the source-neutral
`CatalogPurgeHistory` after either. The m3u names are the same ones
`M3UColdImportBenchmarks` measures, so an Apple TV trace and a simulator run are
comparable *phase by phase* even though their absolute seconds are not — and
this recipe is the only way to see the m3u pipeline on an Apple TV at all, since
`LumePerformanceTests` excludes `appletvos`.

```bash
xcrun xctrace record \
  --device <APPLE_TV_UDID> \
  --template 'Time Profiler' \
  --instrument 'os_signpost' \
  --instrument 'Points of Interest' \
  --attach Lume \
  --time-limit 6m \
  --output ~/Desktop/lume-sync-tvos.trace
```

Start the recording, then trigger the sync on the device — add the playlist of
the kind you are measuring (an m3u URL for the `M3U*` phases, Xtream credentials
for the `Xtream*` ones); a refresh of an already-imported playlist measures a
warm path, not the cold import the complaints are about. `--attach Lume` keeps
launch out of the trace; use `--launch -- <path to Lume.app>` instead if the
question is about launch. Filter the os_signpost instrument to subsystem
`com.bilipp.lume`, category `Performance`.

To read intervals without opening Instruments:

```bash
xcrun xctrace export --input ~/Desktop/lume-sync-tvos.trace --toc
xcrun xctrace export --input ~/Desktop/lume-sync-tvos.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'
```

### 3. Record peak footprint separately

Allocations and VM Tracker distort wall clock badly enough that mixing them into
the Time Profiler run makes both answers useless. Take a second pass:

```bash
xcrun xctrace record \
  --device <APPLE_TV_UDID> \
  --template 'Allocations' \
  --instrument 'VM Tracker' \
  --attach Lume \
  --time-limit 6m \
  --output ~/Desktop/lume-sync-tvos-mem.trace
```

Peak footprint is the number that matters on an Apple TV: no swap, and a sync
that gets jetsammed reads to the user as "the sync never finishes" rather than
as a crash. MetricKit is compiled out on tvOS, so this trace and the signpost
lines in the exported debug log are the only telemetry Apple TV has.

### Baselines from a device are a *new* entry

`.xcbaseline` files are keyed by a hardware hash. An Apple TV baseline is
therefore a separate entry in `xcbaselines/…` and must never overwrite the iOS
one — accepting a device measurement over a simulator baseline silently
re-points every future comparison at different hardware. The same is true of an
iPhone baseline: a device run is an *additional* entry, never an overwrite of
the simulator one.

## Tracing a real iPhone

Everything the simulator suite reports is CPU and resident memory on a Mac. The
complaint that started the m3u work — "6–8 minutes, the phone gets hot, 10% of
the battery" — has three components the simulator physically cannot see:

- **NAND write cost.** The simulator's store is a file on an SSD backed by page
  cache and effectively unlimited write bandwidth. A phone's flash is not, and a
  1.7M-row import is the largest sustained write the app ever performs.
- **Thermal throttling.** A simulator never reports anything but
  `.nominal`, which is exactly why `ImportPacing` takes its thermal state as an
  injected closure and why its policy is pinned by stubbed unit tests rather
  than by a measurement.
- **Battery.** Not observable from a test at all; read it from the Energy Log
  instrument or Settings → Battery after a cold import.

So a device number is a different measurement, not a more accurate version of
the same one — quote it as its own row, never as a correction to a simulator
row.

### 1. Install a Benchmark build

As with the Apple TV: select the **LumePerformance** scheme and Run against the
phone, or

```bash
xcrun xctrace list devices                       # find the iPhone UDID
xcodebuild -project Lume.xcodeproj -scheme LumePerformance \
  -destination 'platform=iOS,id=<IPHONE_UDID>' build
```

Never trace a Debug build.

### 2. Record the import phases — from the GUI

**`xctrace --attach` against a physical iPhone wedges on Xcode 26**: the
recording never finalizes and the `.trace` is unreadable. Record from the
Instruments GUI instead — *Time Profiler* + *os_signpost* + *Points of
Interest*, target the device and the Lume process, start recording, add the
playlist on the phone, stop when the sync cover disappears. Then read the
intervals from the command line:

```bash
xcrun xctrace export --input ~/Desktop/lume-m3u-iphone.trace --toc
xcrun xctrace export --input ~/Desktop/lume-m3u-iphone.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'
```

Filter os_signpost to subsystem `com.bilipp.lume`, category `Performance`. The
twelve signpost names are the same ones `M3UColdImportBenchmarks` measures, so a
device trace and a simulator run are directly comparable *phase by phase* even
though their absolute seconds are not.

### 3. Footprint is a second pass, thermals a third

Allocations and VM Tracker distort wall clock too much to share a run with the
Time Profiler, so peak footprint needs its own recording (*Allocations* + *VM
Tracker*, same target). Thermal behaviour needs a third: the phone has to be
warm before the import starts for `.serious` to appear at all, so record it
after a long playback session or a previous import rather than from cold. Three
questions, three passes — trying to answer them in one gives three bad answers.

## Deliberately not covered

- **Scroll / hitch metrics.** `XCTOSSignpostMetric.scrollDecelerationMetric`
  needs a real device to mean anything, and the worst scroll cost we have
  (the tvOS focus engine) is tvOS-only while this target excludes tvOS by
  deployment target. That stays manual — see *Tracing a real Apple TV* above.
- **Launch time.** Already covered by `LumeUITests.testLaunchPerformance`
  (`XCTApplicationLaunchMetric`), which belongs with the UI tests.
- **Network.** No benchmark touches a provider. Download time is the provider's
  variable, not ours; `M3UDownload` is a signpost so field logs still show it.
