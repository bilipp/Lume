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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM
```

The project injects API secrets from a repo-root `.env` file via `Scripts/inject-env.sh`. The file is gitignored; features degrade gracefully when it's absent.

### Private DerivedData needs a shared package clone

Parallel builds (per platform, per worker, per worktree) each need their own
`-derivedDataPath /tmp/lume-dd-<label>` — the project has several DerivedData
dirs and a bare `xcodebuild` can install a stale app. **Always pair that with
`-clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM`.** Without it
each private DerivedData re-clones the whole package graph — KSPlayer's FFmpeg
xcframeworks plus VLCKit's 865 MB xcframework, **6.4 GB per build dir**; eight
of them once filled `/tmp` with 65 GB. Sharing one clone dir also builds faster
and dodges the botched-checkout race that breaks multi-platform archiving.

Delete your `-derivedDataPath` dir when the task is done, or run
`Scripts/clean-build-cache.sh` (report only; `--apply` to reclaim, `--deep` to
also drop DeviceSupport, the SwiftPM download cache and idle simulators). It
deliberately keeps the two live package checkouts and the main checkout's
`.build/tools` + `.build/lefthook`, which every worktree's pre-commit hook runs
from (`Scripts/lint-tool.sh`). New worktrees: `Scripts/worktree.sh` from inside
the worktree (`--build` to also warm `/tmp/lume-dd-<worktree>`).

---

## Testing

Tests deploy to **iOS 26.4+ Simulator only** — never tvOS. Use an iPhone 17 Pro or newer sim; iOS 26.2 sims fail with a deployment-target mismatch (exit 65).

```bash
# Every invocation below takes the shared package clone — see "Private
# DerivedData needs a shared package clone" above.
SPM=(-clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM)

# Full suite
xcodebuild test -project Lume.xcodeproj -scheme Lume "${SPM[@]}" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Unit tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume "${SPM[@]}" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeTests

# UI tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume "${SPM[@]}" \
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
- **`context.save()` is ~90% of the *Xtream* import.** That figure is from a
  282,288-row Xtream catalog of series shells; it does not describe the m3u cold
  path, where 86% of the entries are episodes. There the biggest single item was
  wiring `Episode.series` through the initializer instead of assigning it after
  `context.insert` — 64% of the whole import.
- **Four knobs were measured at under 6%** — `batchSize` (500/2k/10k/50k all
  within noise), the 11 `#Index` groups on `Movie`, `@Attribute(.unique)`, and
  the per-batch existing-row lookup. On a 178k-row harness that no longer
  exists; only the existing-row lookup has been re-verified at 1.5M rows. Don't
  re-derive them; `LumePerformanceTests/README.md` carries the numbers.
- **`M3UColdImportBenchmarks` is the end-to-end one** — it drives the real
  `ContentSyncManager.syncPlaylist` over a provider-shaped `file://` playlist,
  with clock, peak RSS and every m3u signpost in one pass.
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
│   └── Images/              ImageCache, ImagePipeline (CachedAsyncImage is a view: Views/Components/Images)
└── Views/                   SwiftUI, platform-adaptive
    ├── Home/                Hero carousel, rails, tvOS fold
    ├── Player/              Engine wrappers + unified overlay
    ├── Components/          Shared building blocks, grouped: Cards, Compat, Detail, Images, Library, Playlists, Status
    └── …
```

### Where a view goes
- A view lives in its feature folder until a **second** feature uses it, then it
  moves to `Views/Components/<group>/`. A component only one feature uses moves
  back into that feature.
- Screens don't count: one feature opening another's screen
  (`FullScreenPlayerView`, `MovieDetailView`) is navigation, not reuse.
- A doc comment that only *mentions* a type ("matches `HomeRow`'s heading") is
  not a use.
- A shared component gets its own file, not a slot in a feature's grab-bag file.
- The app is one module, so nothing flags a cross-feature reference. Placement
  is a review concern. Moves are free: no imports to fix, and `Lume/` is a
  synchronized folder, so the pbxproj doesn't change.

Three separate `ModelContainer`s:
- **Catalog** (`default.store`) — local-only, what all `@Query` bindings target
- **CloudKit mirror** (`CloudUserData.store`) — user state (profiles, watch progress, favorites); never bind `@Query` against this container
- **Lume Cloud mirror** (`LumeCloudUserData.store`) — the same mirror models (minus `SyncedBackendChoice`) plus the transport's bookkeeping (`LumeCloudRecordState`, `LumeCloudSyncMeta`); local-only (`cloudKitDatabase: .none`, outside the app group), never bind `@Query` against it either

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
- Our own FFmpeg 9 engine, developed in the sibling repo [`bilipp/LumeEngine`](https://github.com/bilipp/LumeEngine) and referenced as a **local** SPM package at `../LumeEngine` — a clone without that sibling (and its FFmpeg xcframework built once) will not resolve. It has its own `AGENTS.md` and a `PLAN.md` that is authoritative for engine design.
- App-side wiring only lives here (`Lume/Views/Player/LumeEngine*.swift`); demux/decode/render/sync bugs are engine-side. Decide which side a bug belongs to *before* editing.
- Declared last in `PlayerEngineKind` so it appends to the end of existing priority lists — opt-in, never silently promoted while KSPlayer is the default.
- The engine never retries on its own schedule: reconnect/backoff, engine fallback, and overlays stay Lume's job. If a fix would add retry policy to the engine, it belongs here instead.

### LumeRecorder (DVR backend)
- Recording-server support talks to our own self-hosted server, developed in the sibling repo [`bilipp/LumeRecorder`](https://github.com/bilipp/LumeRecorder). Its zero-dependency client is referenced as a **local** SPM package at `../LumeRecorder/Kit` (product `LumeRecorderKit`, static, link-only) — a clone without that sibling will not resolve.
- Never edit the Kit from this repo. If its API is insufficient, change it in LumeRecorder and pair the commits.
- App code talks to the `RecordingServerBackend` protocol (`Lume/Services/Recording/`); `LumeRecorderBackend` is the only implementation and owns its own `URLSession`. The client never retries — don't wrap POST/DELETE in retry helpers.
- The paired server is `SyncedRecordingServer` in the **CloudKit** schema (token is `.allowsCloudEncryption`); recordings themselves are never stored in SwiftData. `CD_SyncedRecordingServer` must be deployed to CloudKit **Production** before release.
- Stream URLs, playback grant URLs and tokens never go into logs or diagnostic exports.

### LumeCloud (sync backend)
- Lume Cloud is the optional, end-to-end encrypted alternative to iCloud, developed in the sibling repo [`bilipp/LumeCloud`](https://github.com/bilipp/LumeCloud). Its client is referenced as a **local** SPM package at `../LumeCloud/LumeCloudKit` (product `LumeCloudKit`) — a clone without that sibling will not resolve. `../LumeCloud/spec/PROTOCOL.md` is normative for the wire format, logical keys and payload fields.
- Never edit the Kit from this repo. If its API is insufficient, change it in LumeCloud and pair the app↔Kit commits. The only files written there from here are the generated `spec/vectors/` (`LumeCloudVectorExportTests`, `LUME_EXPORT_VECTORS=1`).
- The client never retries — backoff (429 `retryAfter`), reconnect and resync stay in `LumeCloudTransport`/`LumeCloudBackend` (`Lume/Services/Sync/LumeCloud/`). Don't wrap Kit calls in retry helpers.
- The server URL comes only from build config: `LUME_CLOUD_URL` in `.env` → `LumeCloudServerURL` in Info.plist (`Scripts/inject-env.sh`), read by `LumeCloudConfig`. Unset, Debug talks to **staging** (`cloud-staging.getlume.org`) and Release to `cloud.getlume.org`. There is no UI for it.
- The `accountId` is **derived from the root key** (`LumeCloudKeys.accountId`): create with `createAccount(keys:)` (409 → `.accountExists`) and authenticate with `Credentials(keys:deviceID:)`. A recovery-key restore derives it, registers a **fresh** device UUID and wipes the Lume Cloud mirror + bookkeeping so the next pull runs from `since=0`.
- iCloud stays the default; switching (iCloud / Lume Cloud / Off) only goes through `CloudSyncCoordinator.switchBackend`, which also covers auto-join, Leave, Delete and revoke. Its mirror is the `LumeCloudUserData` container above.
- Off writes to no mirror: a playlist deleted while Off leaves the catalog only, so it can come back from the mirror when the device rejoins iCloud or Lume Cloud (the first reconcile after a switch is a union merge).
- The `CloudSyncShadow` is **per backend**: legacy `cloudsync.shadow.*` keys are iCloud, `cloudsync.lumecloud.shadow.*` are Lume Cloud. The switch procedure calls `resetAll()` on the **target** namespace before the first reconcile against the target mirror — skip it and the stale baseline mass-deletes the user's data.
- **Push change detection is history-based.** Every transport `ModelContext` writes as `LumeCloudTransport.contextAuthor`; a push diffs only mirror rows other authors changed since `LumeCloudSyncMeta.historyToken`, plus dirty/pending-deletion states. A nil or expired token (first pass, `resetBookkeeping`, resync, backend switch, mirror wipe) falls back to a full diff. The token is stored only after the push succeeds. Bookkeeping writes are if-different, so an unchanged push saves nothing. The transport owns this store's history; `purgeCatalogHistory` never touches it.
- **Empty Lume Cloud mirror ≠ always store loss.** An empty mirror with synced records behind it resets the bookkeeping and pulls from 0, and pushes no tombstones for it. The exception is a mirror the user's own recorded deletions emptied (`isDeletionPending`): its tombstones push normally. A store-loss reset keeps unpushed recorded deletions, so the pull can't bring them back.
- **Undecodable records are held, never lost.** A pulled record that doesn't open (unknown type, unsupported envelope version, undecodable payload, rid mismatch) is kept on its `LumeCloudRecordState` (`isUndecodable` + raw ciphertext, version, seq) while the cursor advances; every pull retries them first, so they apply after an app update. Pushes never overwrite or delete a held rid.
- The Apple-wide handoff record is `SyncedBackendChoice` in the **CloudKit** schema (`rootKey` is `.allowsCloudEncryption`). `CD_SyncedBackendChoice` must be deployed to CloudKit **Production** before release. `SIDE_LOAD` builds never touch it (or CloudKit at all).
- No account IDs, device IDs, keys, recovery keys, pairing codes, payloads or `Bearer` credentials in logs or diagnostic exports — `LogRedaction` scrubs `Bearer`, and `DebugLogExporter` reports only backend, state, last sync/error and server type.

### Localization
String Catalogs (10 languages: ar, en, de, es, fr, it, ja, ko, pt, zh-Hans; the App Store listing mirrors them — see `ship-release`'s `references/store-metadata.json`). Run `xcstringstool sync` and include the tvOS stringsdata. Normalize `.xcstrings` with `Scripts/normalize-xcstrings.swift` (pre-commit hook) to avoid format churn.

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
