# Lume — AI Agent Guide

Lume is a native, multi-platform IPTV player (iOS 18+, macOS 15+, tvOS 18+, visionOS 2+) built with SwiftUI + SwiftData. Single Swift codebase with four interchangeable playback engines: KSPlayer (default) → VLCKit → AVPlayer, plus the opt-in beta LumeEngine (sibling repo `../LumeEngine`). It is built with the iOS 26 SDK and uses Liquid Glass / iOS 26 navigation APIs where available, falling back to system materials on older OS versions.

---

## Build & run

```bash
# Open in Xcode
open Lume.xcodeproj   # pick scheme "Lume", any destination

# CLI build (iOS Simulator)
xcodebuild build \
  -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The project injects API secrets from a repo-root `.env` file via `Scripts/inject-env.sh`. The file is gitignored; features degrade gracefully when it's absent.

---

## Testing

Tests deploy to **iOS 26.4+ Simulator only** — never tvOS. Use an iPhone 17 Pro or newer sim; iOS 26.2 sims fail with a deployment-target mismatch (exit 65).

```bash
# Full suite
xcodebuild test -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Unit tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeTests

# UI tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeUITests
```

Every test `ModelConfiguration` must set `cloudKitDatabase: .none` — `@Attribute(.unique)` models + the default `.automatic` crashes on entitled simulator hosts.

---

## Performance testing

Benchmarks live in their own target (`LumePerformanceTests`), scheme
(`LumePerformance`), test plan (`Performance.xctestplan`) and build configuration
(**Benchmark** = Release + `ENABLE_TESTABILITY`). They are *not* in the `Lume`
scheme, so a normal `xcodebuild test` never runs them.

```bash
Scripts/run-performance-tests.sh                    # whole suite + measurements
Scripts/run-performance-tests.sh ParsingBenchmarks  # one suite
```

- Never benchmark in Debug — `-Onone` makes parser/import numbers fiction. That's
  what the Benchmark configuration exists for.
- Store benchmarks use **on-disk** containers (`PerfStore`); in-memory skips
  SQLite, the very cost being measured.
- Fixtures are generated per run from a fixed seed (`PerfFixtures`), never
  committed.
- App-defined phases are named once in `Services/Diagnostics/PerformanceSignposts.swift`
  (`Perf.begin`/`Perf.end`). Those names are a contract with `SignpostBenchmarks`
  and feed Instruments' Points of Interest lane — rename one and update both.
- Field layer, in the shipping app: `AppPerformanceMetrics` (MetricKit; compiled
  out on tvOS) and `PlaybackQoE` (join time, rebuffer ratio, exits before video
  start, engine fallbacks). Both surface in the exported diagnostic report.
- `PlaybackQoE` flushes to `UserDefaults` at session boundaries only — never
  periodically, which is what used to hitch KSPlayer.

See `LumePerformanceTests/README.md` for baselines and why there is no CI gate.

---

## Architecture

```
Lume/
├── LumeApp.swift            App entry + SwiftData containers
├── Models/                  SwiftData @Model types (Playlist, LiveStream, Movie, Series, …)
├── Services/
│   ├── Network/             XtreamClient, M3UClient, TMDBClient, MDBListClient, TraktService
│   ├── Sync/                ContentSyncManager (background catalog indexing + enrichment)
│   ├── Player/              PlayerSettings, PlayerHistory, NextUp resolver
│   ├── Diagnostics/         Perf signposts, PlaybackQoE, MetricKit subscriber
│   └── Images/              CachedAsyncImage, ImagePipeline
└── Views/                   SwiftUI, platform-adaptive
    ├── Home/                Hero carousel, rails, tvOS fold
    ├── Player/              Engine wrappers + unified overlay
    └── …
```

Two separate `ModelContainer`s:
- **Catalog** (`default.store`) — local-only, what all `@Query` bindings target
- **CloudKit mirror** (`CloudUserData.store`) — user state (profiles, watch progress, favorites); never bind `@Query` against this container

---

## Key patterns & gotchas

### Swift concurrency
`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` is set project-wide. Value types and DTOs used by `nonisolated` callers must be explicitly marked `nonisolated` (type + every extension).

### SwiftData
- Enrichment saves run on a **background** `ModelContext` (`ContentSyncManager.enrich*`) — not the view context.
- Main-thread saves during playback stall KSPlayer every ~5 s. Buffer to `UserDefaults`; flush at playback boundaries.
- `PlaylistDeletion` helper must be used for any playlist removal (UI **and** iCloud reconcile) — `Movie`/`Series`/`LiveStream` have no cascade relationship to `Playlist`.
- The reconciler after `switchProfile` rebuilds the dropped content shadow — don't remove that pass; optimize the fetch predicate instead.

### iCloud sync
- Guard reconcile against `LocalCatalogReadiness`; an empty `default.store` would push mass deletions to CloudKit.
- `UserProfile` must be deduped on every reconcile (not just launch) — fixed-id default profiles multiply per device in CloudKit.

### tvOS-specific
- `Color.accentColor` resolves to white on tvOS — never use it for fills/tints.
- `.onMoveCommand` runs inside the focus engine's animated context; defer layout mutations with `Task { }`.
- Full-width focus targets needed for vertical navigation — a narrow target won't catch "down" from a full-width section.
- `@FocusState` must not drive layout sizing in the hero fold — use `TVHomeScreen`'s `ScrollTargetBehavior`.

### KSPlayer
- Hardware decode requires **both** `asynchronousDecompression = true` **and** `hardwareDecode = true`; `async` defaults to `false` → silent software decode → frame drops on tvOS.
- Never call `layer.prepareToPlay()` on a running session — use `player.replace()` (`rebuildStream(on:)`) to avoid a UAF crash.
- Frozen image + healthy audio on live TV = MPEG-TS 2³³ clock wrap; fixed by the `noteClockDrift()` watchdog.

### LumeEngine (beta, 4th engine)
- Our own FFmpeg 8 engine, developed in the sibling repo [`bilipp/LumeEngine`](https://github.com/bilipp/LumeEngine) and referenced as a **local** SPM package at `../LumeEngine` — a clone without that sibling (and its FFmpeg xcframework built once) will not resolve. It has its own `AGENTS.md` and a `PLAN.md` that is authoritative for engine design.
- App-side wiring only lives here (`Lume/Views/Player/LumeEngine*.swift`); demux/decode/render/sync bugs are engine-side. Decide which side a bug belongs to *before* editing.
- Declared last in `PlayerEngineKind` so it appends to the end of existing priority lists — opt-in, never silently promoted while KSPlayer is the default.
- The engine never retries on its own schedule: reconnect/backoff, engine fallback, and overlays stay Lume's job. If a fix would add retry policy to the engine, it belongs here instead.

### Localization
String Catalogs (9 languages: en, de, es, fr, it, ja, ko, pt, zh-Hans; the App Store listing mirrors them — see `ship-release`'s `references/store-metadata.json`). Run `xcstringstool sync` and include the tvOS stringsdata. Normalize `.xcstrings` with `Scripts/normalize-xcstrings.swift` (pre-commit hook) to avoid format churn.

### Pre-commit hooks (lefthook)
SwiftFormat + SwiftLint run as errors. Notable: `String(decoding:)` is banned; `redundantStaticSelf` crashes on `for x in (try? …) ?? []` — avoid that pattern.

---

## External integrations

| Service | Auth | Notes |
|---------|------|-------|
| TMDB | Bearer token (`.env`) | Metadata, artwork, trailers |
| MDBList | API key (`.env`) | IMDb / RT / Metacritic / Trakt / Letterboxd ratings |
| Trakt | Device OAuth (Keychain) | Scrobbling; no web view — works on tvOS |

---

## GitHub
Issues & roadmap: <https://github.com/bilipp/Lume/issues>
