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

## Stores are on disk, not in memory

`PerfStore.makeOnDiskContainer()` creates a real store file per iteration. An
in-memory `ModelContainer` skips SQLite entirely, so it understates import cost
by roughly an order of magnitude — and import is the phase users wait minutes on.
(It also hides SQL-generation behaviour outright; a predicate crash we once
shipped only reproduced on-disk.)

Every configuration sets `cloudKitDatabase: .none`, without exception: the
catalog's `@Attribute(.unique)` models crash container load when CloudKit
mirroring is left at `.automatic` on an entitled host.

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

## Deliberately not covered

- **Scroll / hitch metrics.** `XCTOSSignpostMetric.scrollDecelerationMetric`
  needs a real device to mean anything, and the worst scroll cost we have
  (the tvOS focus engine) is tvOS-only while this target excludes tvOS by
  deployment target. That stays a manual `xctrace` recipe.
- **Launch time.** Already covered by `LumeUITests.testLaunchPerformance`
  (`XCTApplicationLaunchMetric`), which belongs with the UI tests.
- **Network.** No benchmark touches a provider. Download time is the provider's
  variable, not ours; `M3UDownload` is a signpost so field logs still show it.
