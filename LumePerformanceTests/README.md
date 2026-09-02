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
| Microbenchmarks | `ParsingBenchmarks`, `PersistenceBenchmarks`, `EPGQueryBenchmarks` | Parser / import / query regressions |
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

### The m3u fixture shape changed with the catch-up feature (issue #203)

The catch-up branch moved the parser **and** the fixture in the same change, so
`testM3UParse120kEntries` numbers do not compare across it without care.

What changed in the fixture: `PerfFixtures.writeM3U` now appends
`catchupAttributes(index:)` to every live entry — a `switch index % 12` whose
cases 0–5 emit an attribute block and whose default emits nothing, so roughly
half the live entries carry catch-up attributes and the other half exercise the
lookup-misses. It is keyed off `index` rather than the LCG on purpose: the draw
sequence, and therefore the live/movie/series mix, is byte-identical to before.
`reserveCapacity` went `entryCount * 180` → `* 200` to keep generation
realloc-free.

Measured at 120k entries: **20,364,387 B (169 B/entry) before,
21,557,041 B (179 B/entry) after** — 5.9% more input. `assertFixtureIsSubstantial`'s
floor moved 5 MB → 18 MB in the same change; the point of the raise is that the
old 5 MB floor was so far below the real size that a generator dropping an entire
attribute block would still have passed it. Note the old-shape fixture is
*20.4 MB*, i.e. still above the new 18 MB floor — the floor does not encode the
new shape, it just stopped being useless.

#### De-confounding the reported 25% regression

The fresh-eyes review measured m3u parse of 120k entries going 0.851 s →
1.067–1.421 s and attributed it to the extra per-`#EXTINF` dictionary lookups.
Because code and input moved together, that attribution could not stand as
measured. The experiment below moved them one at a time, in one process, in one
run, under the Benchmark configuration on an iPhone 17 Pro simulator.

Method: a throwaway `LegacyM3UParserExperiment.swift` in this target carried
verbatim copies of the pre-branch parser (commit `76044b6`), of the branch's
parser *as the review saw it* (before finding 7 added the display-name boundary
to `parseAttributes`), and of the shipping parser, plus an old-shape
`writeM3U`. Six cells, `XCTClockMetric`, five iterations each, five back-to-back
runs on an otherwise idle machine; medians below.

| Cell | Parser | Module | Fixture | Median |
|---|---|---|---|---|
| A | shipping | Lume | old shape | **0.954 s** |
| B | pre-branch (76044b6) | test | old shape | **1.466 s** |
| C | shipping | Lume | new shape | **0.883 s** |
| D | as-reviewed | test | new shape | 1.434 s |
| E | as-reviewed | test | old shape | 1.342 s |
| F | shipping (verbatim copy) | test | old shape | 1.233 s |

The *module* column is load-bearing and was the trap in the first pass. A
verbatim copy of the shipping parser compiled into the test target (F) runs
**29% slower than the identical source called across the module boundary into
Lume (A)** — 1.233 s vs 0.954 s. Every legacy/as-reviewed cell pays that
handicap and cells A and C do not, so a raw A-vs-B comparison overstates the
shipping parser by roughly that much. F is the control that makes the
same-module rows comparable to each other.

What the cells say:

- **Code, isolated (F vs B, same module, same input): the shipping parser is
  15.9% *faster* than the pre-branch one.** Finding 7's fix stops attribute
  scanning at the comma that starts the display name, so `parseAttributes` no
  longer walks the name of every line — which more than pays for the six extra
  dictionary lookups the feature added.
- **Fixture shape, isolated (A vs C): no cost.** 0.954 s on the old shape vs
  0.883 s on the new one; 5.9% more bytes did not make the parse slower, and
  the direction is inside the run-to-run spread either way.
- **Where the review's number came from (D and E):** only the as-reviewed
  parser reproduces it. D is 1.434 s in the test module; divided by the 1.29
  module handicap that is ~1.11 s in Lume-module terms, squarely inside the
  review's 1.067–1.421 s band. Its old-shape twin E is 1.342 s, so the fixture
  contributed ~7% of that and the attribute scan the rest.

Caveat, so nobody over-reads the table: the pre-branch parser could only be
measured as a test-module copy — swapping it into `Lume/` does not compile,
because `ContentSyncManager+M3U` and `ParsingBenchmarks` read the new
`M3UEntry` catch-up fields. Cross-module rows are therefore comparable to each
other, not to A and C. B is also the noisiest cell in the set (1.30–1.62 s
across runs); F and E are stable to a few percent.

Verdict: the 25% is not a real regression in the shipping parser — it was the pre-finding-7 attribute scan, which no longer exists; on identical input in identical module placement the current parser is 15.9% faster than the pre-branch one (F 1.233 s vs B 1.466 s), the new fixture shape costs nothing measurable (A 0.954 s vs C 0.883 s), and there is nothing here to optimize.

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
