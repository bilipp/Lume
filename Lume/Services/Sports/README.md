# Sports

The Sports Hub (#34): followed leagues' and teams' fixtures, live scores,
standings and game detail from ESPN, each fixture resolved to a channel already
in the viewer's own playlists via the EPG so one tap starts playback.

Sports is a **Lume Pro** feature (`PremiumFeature.sportsHub`) and ships behind
the `sports.tabEnabled` toggle (default on). It is a browse-and-play layer on top
of the existing catalog: it never adds channels. Live playback targets an imported
`LiveStream`; Replays use the existing recording-server or catalog player.

## Layout

```
Services/Sports/
├── SportsModels.swift        Value types: SportsFixture / Competitor / Team /
│                             League / StandingRow / F1 sessions
├── SportsEventDetail.swift   Game-detail value types: key events, stats, lineups
├── SportsTennis.swift        Set scores, the tour's singles draw, round labels
├── SportsDataProvider.swift  The source-agnostic protocol (below)
├── ESPNClient.swift          v1 provider — ESPN's keyless site/web API
├── ESPNClient+Tennis.swift   Tennis's tournament/draw shape and the rankings
├── ESPNDTOs.swift            All-optional Codable DTOs for the ESPN JSON
├── SportsCatalog.swift       League lookups, browse order, per-region defaults
├── SportsCatalog+Leagues.swift  The curated table itself (~160 leagues, 23 sections)
├── SportsCacheStore.swift    On-disk JSON snapshot per league (below)
├── SportsCrestTint.swift     Fallback team colour read off the crest (below)
├── SportsStore.swift         @MainActor @Observable — what the UI reads
├── SportsSyncService.swift   Short-lived cache refresh + the live-score poll
├── SportsFollowService.swift Follows (per profile, ordered) + region pre-follows
├── SportsMatcher.swift       Pure team-token matching (+ SportsTeamAliases.json)
├── SportsChannelResolver.swift  Fixture → channel resolve (below)
├── SportsChannelResolver+Racing.swift  Race sessions: series + session words
├── SportsChannelResolver+Competition.swift  Tour-wide blocks (tennis)
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
the single source every sports view reads. `SportsSyncService` fills it. There
is no refresh schedule: a snapshot is fresh for `freshness` (5 min), and every
surface that shows sports data — the Home rail, the hub, the app returning to the
foreground, a follow change — calls `refreshIfStale()`, which re-fetches the
months and standings of each followed league past that age. While a sports
surface is visible a 60 s loop (paused during playback) does the same, and also
re-fetches by day the leagues holding a live or overdue game. The day poll leaves
`fetchedAt` alone, so it never postpones a league's full refresh. A league that
answers empty — ESPN's shape for both a failure and an off-season league — stays
stale but is retried at most once a minute.

## Tennis

ESPN has two tennis leagues, `tennis/atp` and `tennis/wta`, and neither looks
like a team sport. A scoreboard event is a whole tournament; its matches sit in
`groupings[]` per draw (men's singles, women's doubles…), not in `competitions`.
`ESPNClient+Tennis` makes each match its own two-sided fixture, and keeps only
the tour's own main-draw singles: the WTA feed carries a combined event's men's
draw too, and qualifying, doubles and TBD slots would add hundreds of cards a
month. `name` is the tournament and `round` its stage, which the card and the
detail sheets show as "China Open · Quarterfinal". A match not yet on an order
of play has `timeValid: false` and a placeholder start, so it shows "TBD".

A player stands in for a team: the athlete id is the team id, the country flag
is the crest (headshots exist only for the top players), and `sets` carries the
games per set while `score` is the sets won. `/teams` and `/standings` come back
empty, so the world ranking (`/rankings`, top 150) supplies both the followable
players and the table (`SportsStandingKind.player`). `/summary` is an HTTP 400
for every id, so a match has no timeline or stats. The channel matcher uses a
player's surname only, since a first name alone would match every namesake.
Tennis channels mostly air a tour-wide block for hours ("Live ATP & WTA: Die
Topspiele des Tages"), so a match with a real time slot also picks up any
programme naming its tour that is on air at its start, as the lowest tier
(`epgCompetition`), ranked by the tournament name ("Chengdu") in the headline.

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
| 5 | `epgCompetition` | A tour-wide block on air at the start that names no match (`"Live ATP & WTA: Die Topspiele des Tages"`) — tennis only, see `SportsChannelResolver+Competition`. Never confident: the block may not show this match. |

A team is "present" when any distinctive token from `SportsMatcher.tokens(for:)`
(aliases from the bundled `SportsTeamAliases.json`) appears as a whole word in a
`SportsMatcher.normalize`d haystack.

### Race sessions

A race session (an F1 weekend card per session, see `expandedBySession`) has no
two teams, so `SportsChannelResolver+Racing` matches it on the **series**
(`SportsRaceMatcher.seriesPhrases`: "F1", "Formel 1", "Formula 1"…) and the
**session** named in the guide ("1. Freies Training", "Practice Two", "Quali",
"Das Rennen"…, in the app's languages). The same tiers apply:

| Tier | Race signal |
|---|---|
| `epgTitleSubtitle` | Series and this session together in one field — or the session on a series-named channel ("Sky Sports F1" · "1. Freies Training"). |
| `epgSingleField` | The series in the headline, the session split off or not named at all ("Formel 1 - Grand Prix von Aserbaidschan"); the kickoff window decides. |
| `epgDescription` | The series only in the description. |
| `channelName` | A series-named channel with nothing in its guide at the session's start. |

A programme naming a **different** session of the weekend, or a support series
(F2, F3, F1 Academy, Supercup), is never offered. The series phrase is cut before
session words are read, so the "1" of "Formel 1 Training" isn't practice 1.

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


## Replays

The Scores / Replays switch appears when playable replays are available. Native
DVR recordings use the existing recording store, profile restrictions, playback
grants and namespaced progress. A recording joins a game only when its programme
window and both teams identify one ESPN fixture; a late partial may use the
retained programme window. The unnamed-channel fallback requires one fixture in
the actual capture window. Ambiguous recordings remain in the recordings library.

Date windows, team/league search and league / season / phase / week browsing are
shared across platforms. Missing hierarchy levels are skipped. Replay cards hide
results by default, and game detail reuses the existing fixture header. Version
selection, Resume and Watch from beginning keep progress on the original item.

## Optional Sportarr library integration

Settings → Sports has one device-local switch, **off by default**. When enabled,
the normal Jellyfin/Emby/Silo and WebDAV imports capture explicit Sportarr event
IDs, published TVDB aliases or Sportarr filename tokens. An identified league
series, or a series with identified episodes, classifies its other episodes.
Names alone never classify an ordinary movie or show.

`Sportarr/` owns a disposable private JSON index per playlist under Caches/Sports.
It contains catalog IDs and derived metadata, not media URLs, credentials or
SwiftData models. Original files, catalog rows, favorites and progress stay put.
A lost cache costs another resolve. Playlist deletion removes its derived index.

The fixed `https://sportarr.net/api/metadata/agents` client makes keyless GETs to
`episode/{event}`, `series/{league}` and
`series/{league}/season/{year}/episodes`. Requests carry public event/league IDs
and an identifying User-Agent; no viewer identity or local-server credentials.
There is no acquisition API, configurable origin or resolver in a row/player.
All response fields are optional. The serial sync worker stays below two requests
in flight and caps individual event requests at 25 per pass. Season batches and
resolved files are cached; misses back off to weekly, while outages preserve
previous answers. Turning the switch off cancels queued lookups.

League mapping uses exact normalized catalog names/abbreviations plus the small
reviewed `sportarr-league-aliases.json`. A unique two-team/time match joins the
ESPN game. Historical months, including successful empty answers, are cached
separately from Scores. Unmatched identified files remain playable as their own
games, with Uncategorized last. A title-based match is disclosed in detail.

`ContentRestriction` separates browse relocation from category permissions.
Central category/collection/genre/indexer queries exclude classified movies and
series in SQLite; Home uses the same visibility values. Search and Continue
Watching retain the original identities and route to Sports game detail. Playback
revalidates the catalog row and profile restrictions. Sports episodes use the
existing source picker/player, sports titles and original progress, with episode
neighbours, Next Up and Cast auto-advance suppressed.

A partial or per-show import cannot withdraw a cached classification. Complete
walks can restore ordinary browsing when explicit identifiers disappear; confirmed
catalog absence prunes only derived records. Failed reads never mean an empty
catalog. Tests cover these boundaries, request budgets, opt-out, wrong-ID dates,
shared-city ambiguity, private-path exclusion and SQLite paging.

Live acceptance still requires an importable media-server view carrying trusted
identifiers. A collection-only archive with no provider IDs is not evidence that
the integration works, even when login and ordinary playback succeed. Full and
condensed editions must also be verified through the existing source resolver.
