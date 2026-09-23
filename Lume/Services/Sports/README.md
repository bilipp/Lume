# Sports

The Sports Hub (#34): followed leagues' and teams' fixtures, live scores,
standings and game detail from ESPN, each fixture resolved to a channel already
in the viewer's own playlists via the EPG so one tap starts playback.

Sports is a **Lume Pro** feature (`PremiumFeature.sportsHub`) and ships behind
the `sports.tabEnabled` toggle (default on). It is a browse-and-play layer on top
of the existing catalog: it never adds channels, and playback only ever targets a
`LiveStream` already imported from a playlist.

## Layout

```
Services/Sports/
├── SportsModels.swift        Value types: SportsFixture / Competitor / Team /
│                             League / StandingRow / EventDetail / F1 sessions
├── SportsDataProvider.swift  The source-agnostic protocol (below)
├── ESPNClient.swift          v1 provider — ESPN's keyless site/web API
├── ESPNDTOs.swift            All-optional Codable DTOs for the ESPN JSON
├── SportsCatalog.swift       League lookups, browse order, per-region defaults
├── SportsCatalog+Leagues.swift  The curated table itself (~160 leagues, 23 sections)
├── SportsCacheStore.swift    On-disk JSON snapshot per league (below)
├── SportsCrestTint.swift     Fallback team colour read off the crest (below)
├── SportsStore.swift         @MainActor @Observable — what the UI reads
├── SportsSyncService.swift   Schedules refreshes + the live-score poll
├── SportsFollowService.swift Follows (per profile, ordered) + region pre-follows
├── SportsMatcher.swift       Pure team-token matching (+ SportsTeamAliases.json)
├── SportsChannelResolver.swift  Fixture → channel resolve (below)
└── SportsChannelPicks.swift  Device-local remembered channel picks
```

Data model decisions that outrank first instincts:

- **No SwiftData `@Model` for sports data.** Fixtures, standings and teams are
  derived, re-fetchable cache; they live as a JSON snapshot behind `SportsStore`,
  not in `default.store`. Nothing sports-related is ever `@Query`ed.
- **Follows are user state and DO sync** — through the `SyncedSportsFollow`
  mirror in `CloudUserData.store` (per profile, ordered), read via
  `SportsFollowService`, never `@Query`ed against the mirror.
- **Channel picks stay device-local** — a `SportsChannelPicks` `UserDefaults`
  store, because a pick is meaningful only for the playlists on this device.

## `SportsDataProvider`

The source-agnostic seam. It is `nonisolated protocol … : Sendable` with only
`async throws` requirements, so a `nonisolated` conformer runs off the main actor
under the project's default `MainActor` isolation:

```swift
func fixtures(league:month:) async throws -> [SportsFixture]   // a calendar month
func fixtures(league:day:)   async throws -> [SportsFixture]   // one day (live poll)
func teams(league:)          async throws -> [SportsTeam]
func standings(league:)      async throws -> [SportsStandingRow]
func eventDetail(league:eventId:) async throws -> SportsEventDetail?
```

`ESPNClient` is the only conformer today. It hits ESPN's public, keyless site API
and needs no `.env` secret (`isConfigured == true` always). Scoreboards are
fetched with `?dates=YYYYMM` (a whole month) or `?dates=YYYYMMDD` (a single day);
ESPN date **ranges** return zero events, so they are never used. Every request
degrades to an empty result plus a `Logger.network` warning on a non-2xx or a
decode failure, so one bad league can't abort a multi-league refresh — the
resilience is the client's job, not the caller's.

## `SportsCacheStore`

One `Codable` `SportsLeagueSnapshot` per followed league, written to
`Caches/Sports/{leagueId}.json` and replaced wholesale on every refresh. A
snapshot carries the league's `fixtures`, `standings` and `teams`, plus
`fetchedAt` and a separate `teamsFetchedAt` so the rarely-changing crest/colour
roster can be reused for a week instead of re-downloading `/teams` each pass. It
is a `nonisolated struct` so the background refresh reads and writes it without
hopping to the main actor. It lives in `Caches/` (like `ImageDiskCache`), not the
catalog store, because it is disposable.

`SportsStore` (`@MainActor @Observable`) is the in-memory front of the cache and
the single source every sports view reads. `SportsSyncService` fills it: a
scheduled refresh (`SyncFrequency`, key `sports.syncFrequency`) plus a 60 s
live-score poll that runs only while the hub is visible and is paused during
playback.

## Team colours and the crest fallback

Card washes, detail headers and stat bars tint from each team's `colorHex`,
through `TeamPalette`'s contrast floor. ESPN leaves many teams without a usable
colour — no County Championship or T20 Blast club has one, `/teams` 404s for
cricket, and plenty of clubs are `ffffff`/`000000`. For those, the refresh reads
the colour off the crest: `SportsCrestTint.dominantHex` takes the most common
saturated colour in a 96 px thumbnail that clears the same contrast floor,
skipping a colour's own dark anti-aliased edge. Monochrome or pale crests (Spurs,
Juventus, Dortmund) yield nothing and keep the neutral tint.

`SportsSyncService.publish` stamps the result into the snapshot's teams before
storing it, so views need no change. Known tints go in immediately; crests never
seen are fetched (in parallel, through `ImagePipeline`) after the snapshot is
already showing, then merged in. `SportsCrestTintCache` keeps every answer,
misses included, in `Caches/Sports/crest-tints-v1.json` — bump the version when
the extraction changes so old misses don't stick.

## `SportsChannelResolver` — fixture → channel

The resolver answers "which channels in *my* playlists carry this match?"
entirely off the main thread, on its own `ModelContext` in a detached utility
task (modelled on `EPGGuideLoader`). It returns plain `Sendable`
`ResolvedChannel` snapshots — nothing managed crosses back — and runs three
passes, each cheaper than the last only once the earlier ones have narrowed it:

1. **Candidate channels.** One scoped `LiveStream` fetch across *all* playlists,
   with hidden channels and parental-/user-restricted categories excluded in
   SQLite (not in Swift).
2. **Guide window.** One `EPGListing` fetch bounded by the union kickoff window
   *and* the candidate channel ids — never the unscoped time-only scan that once
   froze the guide. It is the one guide fetch that reads `listingDescription`:
   a conference programme ("Sonntags-Konferenz, 6. Spieltag") names its games
   only in the body, so the first 400 characters are searched too.
3. **Matching.** The pure `SportsMatcher` token logic in Swift, plus the viewer's
   remembered picks and a channel-name fallback.

### Ranking

Each candidate is tagged with the strongest signal that matched it, ordered by
`ResolvedChannelSource.rank` (lower is stronger); ties break on the weighted
match `score`, then on proximity to kickoff:

| Rank | Source | Signal |
|---|---|---|
| 0 | `userPick` | The viewer pinned this channel for this competition (`SportsChannelPicks`). |
| 1 | `epgTitleSubtitle` | The EPG programme names **both** teams together in one field (title *or* sub-title) — the fixture line itself. |
| 2 | `epgSingleField` | The EPG programme names both teams, but split across the title and sub-title. |
| 3 | `epgDescription` | Both teams appear only in the programme's description — a multi-game conference whose title says nothing about this fixture. |
| 4 | `channelName` | No EPG match; the channel's own name names both teams (`"DAZN 5 | Bayern vs Dortmund"`). |

A team is "present" when any distinctive token from `SportsMatcher.tokens(for:)`
(aliases from the bundled `SportsTeamAliases.json`) appears as a whole word in a
`SportsMatcher.normalize`d haystack.

### The `isConfident` rule

`isConfident` is set on **exactly one** channel per fixture, and only when a
single channel holds the strongest matched tier alone. If two or more channels
tie at the best rank, none is confident. This is the one case a live card offers
one-tap playback (a play glyph); otherwise the card opens a channel picker.

## Adding a second provider

1. Write a `nonisolated struct` conforming to `SportsDataProvider`, mapping the
   source's JSON to the shared value types in `SportsModels.swift` through
   all-optional DTOs (see `ESPNDTOs.swift`) — degrade to `[]`/`nil` on failure,
   never throw across a whole refresh.
2. Encode the league id as `"{source}:{sport}/{slug}"` so snapshots, follows and
   picks stay namespaced per source. Add its leagues to `SportsCatalog`.
3. Inject it where `ESPNClient.shared` is used (`SportsSyncService`) — nothing in
   the hub, the store, the resolver or the views touches ESPN directly, so no UI
   changes are needed.
4. Team/league/venue names from any provider are shown **verbatim** and are not
   localised.
