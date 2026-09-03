# LumePerformanceTests

Lume's dedicated performance suite. Separate target, separate scheme, separate
build configuration — so it never slows a normal `xcodebuild test`, and so the
numbers mean something.

```bash
Scripts/run-performance-tests.sh                                  # whole suite
Scripts/run-performance-tests.sh ParsingBenchmarks                # one suite
Scripts/run-performance-tests.sh ParsingBenchmarks/testXMLTVDateParsing
```

## Why a separate configuration

The suite builds under **Benchmark** = Release settings + `ENABLE_TESTABILITY`
(+ explicit `-O`). This matters more than anything else here: Debug is `-Onone`,
which makes the parsers several times slower than shipped code and turns every
measurement into fiction. `ENABLE_TESTABILITY` is what still allows
`@testable import Lume` against an optimized build.

`Benchmark` was added rather than reusing Release because enabling testability on
Release would change what ships. Debug, Release and Sideload are untouched.

## The four layers

| Layer | Where | What it catches |
|---|---|---|
| Microbenchmarks | `ParsingBenchmarks`, `PersistenceBenchmarks`, `M3UPersistenceBenchmarks`, `EPGQueryBenchmarks` | Parser / import / query regressions |
| Signpost metrics | `SignpostBenchmarks` | A named production phase getting slower |
| Field telemetry | `AppPerformanceMetrics` (MetricKit) in the app | What users actually experience |
| Player QoE | `PlaybackQoE` in the app | Join time, rebuffering, startup failures |

The last two are not tests — they run in the shipping app and surface in the
diagnostic report the user can export (Settings → Diagnostics). They are listed
here because they are the same measurement programme: the tests tell you whether
a phase regressed on your machine, MetricKit and QoE tell you whether it matters
in the field.

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

**`context.save()` is ~90% of it.** Decode, object construction and the upsert
lookup share the remaining tenth. An optimisation that does not reduce how much
SwiftData has to write, or how often it is asked to write, is aimed at the wrong
tenth.

### Levers that were measured and are dead

Each of these moved import cost by **under 6%** — under the run-to-run noise of a
warm laptop. They were measured on a standalone 178k-row harness rather than
through the suite, so the seconds below are internally comparable but do not line
up with the benchmark table further down. Recorded so nobody spends another day
on them:

| Lever | Result |
|---|---|
| `batchSize` 500 / 2,000 / 10,000 / 50,000 | all within noise |
| Dropping all 11 `#Index` groups on `Movie` | 61.1 s → 60.9 s |
| Removing `@Attribute(.unique)` | 15.98 s → 15.83 s |
| Removing the per-batch existing-row lookup | 62.8 s → 62.6 s |
| One shared context instead of a fresh one per batch | 19.68 s → 19.01 s |

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

First run, iPhone 17 Pro simulator, Benchmark configuration — one machine, one
sitting, so these are comparable to each other and to nothing else:

| Benchmark | Clock | Peak RSS |
|---|---|---|
| `testImportFullM3UCatalog` (cold, ~177k rows) | 27.02 s | 248 MB |
| `testReimportFullM3UCatalogUnchanged` | **5.21 s** | 242 MB |
| `testPruneFullEpisodeCatalogWithNoDeletions` | 0.75 s | 243 MB |

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
| `M3UParser.parse` peak RSS | 502 MB | 10 MB |

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
`importM3UFile` is one uninterrupted synchronous stretch inside an actor job with
no suspension point, so the enclosing pool never drained until the whole file was
done: 502 MB peak RSS against 10 MB with a pool around the loop body.
`ParsingBenchmarks.testM3UParse120kEntries` cannot see this — 120k entries is only
~35 MB, well under where it hurts — which is why the number above is from the real
file and not from the suite.

Attribution for all of this comes from the sub-phase signposts added alongside it
(`M3UParse`, `M3UClassify`, `M3UUpsertLive`/`Movies`/`Episodes`, and one per
sweep), nested inside the existing `M3UImport` boundary so older traces and
baselines still resolve. Before them the m3u import was a single opaque number and
none of the above could have been ranked.

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

What is not known: every `Episode.series` assignment faults the `Series.episodes`
inverse, ~1.48M times, and nobody has isolated that cost. It could dominate
everything measured above. It is also the shape behind closed issue #45's
`PersistentIdentifier … remapped to a temporary identifier` fatal error, so the
question is not only "how slow" but "how safe". The `M3UUpsertEpisodes` signpost
is what will answer it, on a device, against the real file — the benchmarks here
run at a tenth scale, where a tenth of an unknown is still an unknown.

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
feeds Instruments' Points of Interest lane, so the trace shows
`SyncMovies` / `XtreamFetchMovies` / `XtreamDecodeMovies` / `UpsertMovies` /
`PruneMovies` as intervals rather than an undifferentiated wall of stacks.

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

Start the recording, then trigger the sync on the device. `--attach Lume` keeps
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
re-points every future comparison at different hardware.

## Deliberately not covered

- **Scroll / hitch metrics.** `XCTOSSignpostMetric.scrollDecelerationMetric`
  needs a real device to mean anything, and the worst scroll cost we have
  (the tvOS focus engine) is tvOS-only while this target excludes tvOS by
  deployment target. That stays manual — see *Tracing a real Apple TV* above.
- **Launch time.** Already covered by `LumeUITests.testLaunchPerformance`
  (`XCTApplicationLaunchMetric`), which belongs with the UI tests.
- **Network.** No benchmark touches a provider. Download time is the provider's
  variable, not ours; `M3UDownload` is a signpost so field logs still show it.
