# LumeAndroid — notes for the Android app

Status: handoff notes, 2026-10-20. Audience: whoever (human or agent) starts
`bilipp/LumeAndroid`. This file belongs in `LumeAndroid/docs/` once that repo
has a skeleton. Sync design: [`lume-cloud-plan.md`](lume-cloud-plan.md).

The Android app is **native Kotlin/Compose** and shares no code with the Apple
app. It must still be *data-compatible* with it. Part 1 below is the contract,
where any deviation silently breaks sync. Part 2 is lessons learned that cost
real customer reports on Apple.

---

# Part 1 — The interoperability contract (must match byte-for-byte)

The source of truth is `bilipp/LumeCloud/spec/`. Pull it in as a **git
submodule pinned to a tag** and run every vector in it as a unit test. If a
vector fails, Android is wrong. The Apple app is the reference implementation,
and the vectors are exported from its tests.

## 1. Catalog identity

Every catalog row has a string id derived from the provider data. Synced user
state (favorites, progress, hidden, category order, parental restrictions)
addresses rows **only by this id**. There's no lookup table. If Android derives
a different id, the user's state on that item simply never appears, with no
error.

Extracted from the Apple code at `54eb0ce`. The `spec/vectors/identity.json`
file replaces this table once it exists.

`U` = the playlist UUID, **uppercase**, 36 characters with dashes. Swift's
`uuidString` is uppercase and Java's `UUID.toString()` is lowercase, so use
`.toString().uppercase(Locale.ROOT)`.

### Source types (`sourceTypeRaw`)

`xtream`, `m3u`, `stalker`, `webdav`, `jellyfin`, `plex`, `emby`, `silo`.
New cases only ever get appended. (There's no Stremio; it was abandoned.)

### Categories

`U-<live|vod|series>-<apiId>`. **Movie categories use `vod`; movie items use
`movie`.** Don't "fix" that.

### Items

| Source | Movie | Series | Live | Episode |
|---|---|---|---|---|
| Xtream | `U-movie-<stream_id>` | `U-series-<series_id>` | `U-live-<stream_id>` | `<Series.id>-episode-<episode.id>` |
| M3U | `U-movie-<key(url)>` | `U-series-<key(seriesName)>` | `U-live-<key(url)>` | `<Series.id>-episode-<key(url)>` |
| WebDAV | like M3U (no live) | like M3U | — | like M3U |
| Stalker | `U-movie-<sid(id)>` | `U-series-<sid(id)>` | `U-live-<sid(id)>` | `<Series.id>-episode-<(item.id ?? index)>-<episodeNum>` |
| Jellyfin / Emby / Silo | `U-<flavor>-<Item.Id>` | `U-<flavor>-<Item.Id>` | — | `U-<flavor>-episode-<Item.Id>` |
| Plex | `U-plex-<ratingKey>` | `U-plex-<ratingKey>` | — | `U-plex-episode-<ratingKey>` |
Notes on the table:

- **Media servers share one id namespace for movies and series**, so route by
  `SyncedContentKind`, never by parsing the id.
- **Series fallback for media-server episodes:** if an episode's series isn't
  in the library, the series row is `U-<flavor>-name-<mediaServerHash(SeriesName)>`.
- **Series row for Plex episodes:** `U-plex-<grandparentRatingKey ?? ratingKey>`.
- **Stalker episodes:** `index` is the 0-based position in the list, and
  `episodeNum` comes from the `series` array, or `index + 1` if that array is
  empty.

### Category `apiId` per source

| Source | `apiId` |
|---|---|
| Xtream | `category_id`, read leniently. A JSON number `5` becomes `"5"`, and a JSON double becomes `"5.0"`. |
| M3U | The **raw group title**: `group-title="…"` verbatim and not trimmed, else `#EXTGRP:` trimmed, else `Uncategorized`. One category per kind (e.g. `U-live-News` and `U-vod-News`). |
| WebDAV | The root share's last path segment, percent-decoded. |
| Stalker | The category `id`. Items found through the `*` walk use `item.category_id ?? "*"`. |
| Media servers | The library view `Id`. A library with no collection type yields both a vod and a series category. |
| Plex | The section `key`. |
### Hash helpers

These have to be ported **exactly**.

```kotlin
// FNV-1a 64 over raw UTF-8 bytes — NO trimming, case-folding or Unicode normalisation
fun hash64(s: String): ULong {
    var h = 0xCBF29CE484222325uL
    for (b in s.toByteArray(Charsets.UTF_8)) { h = h xor b.toUByte().toULong(); h *= 0x100000001B3uL }
    return h
}
fun key(s: String) = hash64(s).toString(36)                 // UNSIGNED base36, lowercase. Never Long.toString(36).
fun numericId(s: String) = (hash64(s) and 0x7FFFFFFFFFFFFFFFuL).toLong()
fun mediaServerHash(s: String) = numericId(s)               // same function on Apple
fun sid(stalkerId: String) = stalkerId.toLongOrNull()?.takeIf { it > 0 } ?: numericId(stalkerId)
fun plexStreamId(ratingKey: String) = ratingKey.toLongOrNull() ?: numericId(ratingKey)  // no > 0 check
```

Use 64-bit `Long` everywhere; Swift `Int` is 64-bit.

### M3U details that change ids

**URL line**
- Split on `\n`, then trim with Swift's `whitespacesAndNewlines` set. That set
  covers all Unicode Zs characters plus U+0085, U+2028 and U+2029.
- **Java `trim()` and `isWhitespace` are not equivalent**, so write an
  explicit predicate.
- A line that isn't valid UTF-8 is decoded as **ISO-Latin-1**, then hashed as
  the UTF-8 of those characters. Don't use replacement characters.

**Classification order** (it decides the `movie` / `series` / `live` prefix):
1. An episode token in the name → episode.
2. `type` ∈ {video, movie, vod} → movie.
3. The URL contains `/movie/` or `/series/` → movie.
4. The URL contains `/channel/`, `/live/` or `/stream/`, or the file name
   starts with `index.` → live.
5. A VOD extension (`mp4 mkv avi mov wmv flv webm m4v mpg mpeg`) → movie.
6. Otherwise → live.

**Episode token**
- The ICU regex `\bS\d{1,3}\s*E\d{1,4}\b|\b\d{1,3}x\d{1,4}\b`,
  case-insensitive. **Only the first match counts.**
- In Kotlin, use `UNICODE_CHARACTER_CLASS or UNICODE_CASE`, take the first
  match only, and reject non-ASCII digits. If the first match has non-ASCII
  digits, the entry is *not* an episode; don't fall through to a later match.
- The `NxM` form is rejected when the season is above 100.

**Series name**
- The text before the token, trimmed of ` -–—·:|.` plus whitespace. If that's
  empty, use the text after the token.
- Keep the original case.

### WebDAV

- Port `MediaFilenameParser` (about 300 lines) 1:1.
- Composed names use `String.format(Locale.ROOT, "S%02dE%02d", …)`. An Arabic
  or Persian device locale would otherwise produce non-ASCII digits.
- URLs are `URL(string: href, relativeTo: collection).absoluteString`, with
  the server's percent-encoding kept byte for byte. Java's `URI.resolve` and
  OkHttp's resolver differ from this (dot segments, encoding), and **any
  difference re-identifies every WebDAV row**. Cover it with vectors.

### Other synced formats

| Field | Format |
|---|---|
| `SyncedContentKind` | `movie`, `series`, `episode`, `live`, `category`. `contentId` is the row id verbatim. |
| `watchProgress` | **seconds** (not a fraction). Marked-watched = the duration in seconds. A row counts as completed at 90 %. Series, live and category rows carry 0. |
| `hiddenTabsRaw` | comma-separated, no spaces, in declaration order `movies,series,liveTV` (note the camelCase `liveTV`). Unknown tokens are dropped, and empty means nothing hidden. |
| Parental `pinHash` | lowercase hex of `SHA-256(utf8("lume.parental.v1" + pin))`, with a 4-digit PIN |

Lenient numbers: providers mix strings and numbers. Swift `Int(String)`
accepts a sign and leading zeros and rejects whitespace and decimals, which
matches Kotlin's `toLongOrNull()`. Swift `String(double)` prints `5.0`;
exponent forms differ from Kotlin, but they're rare.

## 2. Playlists

- `Playlist.id` is a UUID created once and **preserved across devices**. Never
  regenerate it on Android, because it's the prefix of every catalog id.
- Every `sourceTypeRaw` value must **round-trip**, including the ones Android
  doesn't support yet. A synced playlist of an unsupported type is shown as
  "Not supported on Android yet" and kept. It's never deleted, and its catalog
  is never synced. Deleting it would delete it on the user's Apple devices too.
- Credentials (`username`, `password`, `macAddress`) arrive inside the
  encrypted record. Store them encrypted at rest (Keystore-wrapped key) and
  never log them. **Xtream URLs carry credentials as query items**, so a URL
  never goes in a log line, a crash report or analytics.
- Never write a discovered or redirected host back into `serverURL`; Stalker
  redirectors rotate hosts (see Part 2).

## 3. User state & merge rules

Android implements the same three-way merge as `CloudSyncMerge.swift`. The
inputs are the last-agreed value (the shadow), the local value and the remote
value. `spec/vectors/merge.json` pins it. The summary:

| Field | Rule |
|---|---|
| Playlist config | last write wins |
| `watchProgress` | furthest progress wins |
| `isWatched`, `isFavorite` | OR on conflict, so a conflict never loses a favorite. An *un*-favorite wins only when it's a real edit against the shadow. |
| `isHidden` | union (never silently un-hide) |
| `customOrder`, `favoriteOrder` | prefer a concrete value over nil |
| Content whose playlist is gone | garbage-collected |
| Remote state whose catalog row isn't synced yet | stays **pending**. Keep it and retry after the next catalog sync. Never drop it. |

Hard rules learned the expensive way:

- **An empty or unreadable local catalog must never push deletions.** If the
  catalog DB is empty while the shadow has baselines, reset the shadow and pull
  instead (Apple: `LocalCatalogReadiness`). A glitch once wiped every user's
  playlists across all their devices.
- **A truncated provider download must never prune the catalog.** Gate pruning
  on a *complete* walk, and use a mass-delete guard (if more than N % of rows
  would be deleted, skip and log). A prune deletes favorited rows, and the next
  reconcile reads those as "user cleared state".
- **Keep a shadow per backend.** If Android ever gets a second backend, reuse
  of the shadow equals mass deletion.
- **Profiles:** the default profile has the fixed id
  `00000000-0000-0000-0000-0000DEFA0117`. Use exactly that, so a new device
  converges onto the same profile instead of creating a second "Profile 1".
- `UserContentState` is **per profile** (`profileID`). Parental restrictions
  and the PIN are **account-wide**. `Category.isRestricted` is device-global
  and not synced.
- Per-channel order inside a category is deliberately **not** synced, because
  that would mean one record per channel. Only category order and favorites
  order are.

## 4. Encoded payloads

- JSON per collection, as specified in `spec/payloads/*.schema.json`, with a
  `"v"` schema version.
- **Dates are epoch milliseconds, UTC.** Never send local-time strings.
- **Unknown fields round-trip untouched.** Decode into the known fields plus a
  map of the rest, and write the rest back on the next push. Old Apple app
  versions stay in the field for months, and a newer one may add fields
  Android doesn't know yet, and the other way round.
- Enum raw values are strings and are listed in the schema. An unknown value
  is preserved, never coerced to a default and written back.
- Profile avatars: `symbolName` is an **SF Symbol name**
  (`person.crop.circle.fill`, …). Android needs an SF Symbol → Material icon
  table with a fallback icon, and must **keep the original string** when
  writing. `colorRaw` is a `ProfileColor` palette key; mirror the palette.

## 5. Lume Cloud client

- Protocol: `spec/PROTOCOL.md` + `spec/openapi.yaml` (Ktor or OkHttp +
  kotlinx.serialization).
- Crypto (all available in JCA/Tink; `spec/vectors/crypto.json` must pass):
  - HKDF-SHA256 with `info` `lume-cloud/v1/{enc,id,auth}`
  - `rid = base64url-nopad(HMAC-SHA256(idKey, logicalKey))`
  - Envelope `0x01 | nonce(12) | AES-256-GCM ct | tag(16)`, AAD = `rid`
  - Pairing via **HPKE** (X25519 / HKDF-SHA256 / AES-256-GCM), which Tink
    supports
- Root key: wrap it with an Android Keystore key and store it in DataStore.
  Offer the recovery key (Crockford base32 + QR).
- Sync triggers mirror Apple: app start, foreground, after a catalog sync, plus
  a WebSocket (`/v1/socket`, OkHttp) while in the foreground: the server
  pushes `{"seq":N}`, and the client sends `ping` every 30 s. Background sync uses WorkManager
  (network-constrained, with backoff). Later, FCM data messages from the
  official instance.
- **Lume Cloud is free**, with no Pro gate. The server never sees purchases.
- **The account can disappear from under you.** An Apple device can delete
  the account. On the typed `account_deleted` error, tell the user, switch to
  local-only, and **keep all local data**. When Apple devices merely *leave*
  (back to iCloud), Android sees nothing; the account and its other devices
  keep working.
- Android can never move Apple devices between backends, because that choice
  lives in iCloud. Android always pairs through the HPKE code flow.

## 5a. Lume Pro on Android

- Lume Pro is a **separate Android purchase** through Play Billing. There's no
  link to the Apple purchase and no cross-platform unlock. Mirror Apple's shape
  (monthly subscription + lifetime one-time) if you like, but the product ids
  and pricing are Android's own.
- Verify purchases on the device with the Play Billing Library. Since the
  server isn't involved, this works like StoreKit 2 on Apple. **Acknowledge
  purchases within 3 days**, or Google refunds them automatically.
- **Never sync Pro state.** No synced record carries entitlement or purchase
  data. Settings that configure a Pro feature (e.g. combined playlists) do sync
  as plain data, and each platform decides locally whether the feature is
  unlocked.
- On Apple, Pro features show a crown that leads to the paywall, never a "PRO"
  capsule. Pick an Android-native equivalent, but keep it consistent.

## 6. Other cross-platform contracts

- **Trakt:** device-code OAuth, which works on Android TV. Match items by
  **TMDB id**, not Trakt id. Paginate everything (collections are capped at
  100–250 per page).
- **Simkl:** never call `/sync/all-items` without first comparing
  `/sync/activities` stamps. The shared `client_id` gets **suspended without
  warning**, for every install on both platforms.
- **OpenSubtitles:** the API key identifies the build, and downloading needs a
  *user* token from `/login`. Sort query items alphabetically and lowercase the
  values (otherwise you get a 301), send **exactly one** id
  (tmdb *or* imdb), use bare-digit IMDb ids, and episodes key on the parent
  series' ids plus season and episode.
- **LumeRecorder (DVR):** its Kit is Swift-only, so Android needs a Kotlin
  client. The API needs an OpenAPI spec in LumeRecorder first. Playback uses
  short-lived path-signed HLS URLs (no headers needed). Pairing is Bonjour
  `_lume-recorder._tcp` (Android: NSD) plus a 6-digit code.
- **API keys** (TMDB, MDBList, Trakt, OpenSubtitles, Simkl): from
  `local.properties`/env into `BuildConfig`, never committed, matching the
  Apple `.env`. Features hide themselves when a key is missing.

---

# Part 2 — Lessons from the Apple app

## Providers (protocol quirks — reproduce the workarounds)

**Xtream**
- Decode **leniently**: providers send numbers as strings and the other way
  round (`category_id`, `port`, `exp_date`, …).
- A response with entries where none decodes (an `{"error":…}` body) must
  **throw**, never come back as an empty list. Otherwise a prune wipes the
  catalog.
- Name the action and the field path in error logs, never the URL.
- Live fails with **405 on every engine while VOD works** →
  `user_info.allowed_output_formats` excludes the container. On "Automatic",
  pick an allowed format (ts vs m3u8).
- Providers cap **concurrent connections per account**. Never run EPG
  (`xmltv.php`) and catalog sync against the same host at once.
- Sync movies, series and live independently, so one failing endpoint doesn't
  abort the rest. (Apple still aborts on the first decode error; don't copy
  that.)
- Series episodes only come from a per-series `get_series_info`. A series the
  user never opened has no episodes, which matters for the Trakt import: fetch
  episodes before matching.

**M3U**
- Big lists are normal (600k entries, 100 MB). Stream-parse, don't load the
  whole file. On Apple, the **DB import** (not the download) took 4–5 minutes.
  Batch inserts in transactions, and skip the import entirely when the
  ETag/hash is unchanged.
- Only write fields that changed. Rewriting `num` on every refresh dirtied
  every row.
- A killed or cancelled sync must not make the playlist "due" again at every
  launch. Stamp the attempt, back off, and offer an Off/manual frequency.
- Identity is the URL hash, so provider URL churn changes ids. That's
  unavoidable, but never let it look like user deletions (see the prune rules
  in Part 1).

**XMLTV / EPG**
- Accept timestamps **without a UTC offset**: `20260730130000` is valid XMLTV
  and means UTC. Apple silently dropped such guides.
- Parse in a streaming way, not with a per-element `DateFormatter`-style
  allocation. On Apple, XMLTV parsing caused a 9 s post-sync freeze.

**Stalker / Ministra**
- `get_ordered_list` page size is **fixed at 14** server-side. Walk the
  `*` "All" pseudo-category once (items carry their real `category_id`)
  instead of walking each category, which is 12k requests vs ~6 hours.
- Fetch about 6 pages concurrently; portals return 503 above roughly 10.
- The default sync is a recent slice (3,000 newest per kind); "Download Full
  Catalog" is opt-in.
- Xtream-UI emulations ignore the encoded `cmd` in `create_link`. Also send
  the cmd's embedded query params (minus `mac`/`play_token`/`token`) as
  top-level params. An empty `stream=` in the result means fail fast.
- Redirector domains: if every handshake candidate returns HTML, GET the
  pasted URL, follow redirects, and retry at the final host. Don't persist that
  host.
- `get_profile` can return `status:1` plus `msg` = **device blocked**, after
  which every call returns HTTP 200 `Authorization failed.`. Surface the
  provider's message, and don't report "0 categories" as success.
- Send the MAG user agent plus the `mac` cookie. When something is odd, replay
  the flow with curl.

**Jellyfin-compatible servers**
- **AIOStreams** emulates Jellyfin. Get episodes only per show; versions come
  only from `PlaybackInfo`, which is rate-limited to 10 per 15 s, so never call
  it at sync or when a detail screen opens. The API limit is 250 requests per
  30 s per IP.
- **Silo:** native login → `/api/v2/compat/connect-info`, then speak Jellyfin
  to the compat URL. Its `public_url` defaults to loopback, so swap in the
  entered host.

**Sports (ESPN site API)**
- `dates=YYYYMM` returns the whole month, while date *ranges* return zero
  events.
- Never add `?level=1` to standings.
- Refresh on appear with a 5-minute TTL.

## Playback (Android-native)

- Engine: **Media3/ExoPlayer** as the default (HLS, MPEG-TS, DASH), with the
  **Media3 FFmpeg decoder extension** for AC-3/E-AC-3/DTS/TrueHD where the
  device lacks a decoder. Use **libVLC** as the fallback engine, the same role
  VLCKit plays on Apple. Keep engine fallback, reconnect and backoff in the app
  layer, never inside the engine.
- **Time to first frame is a top complaint.** Apple shipped 8 s VOD / 4 s live
  pre-buffer defaults, and users noticed against competitors. Start with small
  buffers (live about 1 s, VOD 2–3 s) and a small probe size for live TS.
- **Live MPEG-TS 2³³ PTS wrap (~26.5 h):** frozen video with healthy audio.
  Detect drift between the audio and video clocks and re-prepare the source.
  It's unrecoverable otherwise.
- Android TV **match content** (refresh rate / dynamic range): use
  `Surface.setFrameRate` / display-mode switching, and **never in embedded
  preview tiles**. Each switch is an HDMI re-sync (black screen); Apple learned
  this with channel-preview zapping.
- Don't write to the DB on a timer during playback. Buffer progress in memory
  or preferences, and flush at play/pause/stop boundaries. (On Apple, periodic
  saves stuttered the player every 5 s.)
- Record QoE (join time, rebuffer ratio, exits before video start, engine
  fallbacks) and include it in the diagnostic export, as `PlaybackQoE` does.
- Chromecast is native on Android (Cast SDK). A Media3 `CastPlayer` swap
  replaces the custom Apple work.

## Data layer

- **Two databases**, like Apple: the catalog (large, local, re-derivable;
  Room) and user data (the small mirror that syncs). Keep sync writes away from
  the catalog DB's observers, or every UI query re-runs on each sync. On Apple
  this froze the UI on every foreground.
- Index for real access paths. On Apple, the default locale-aware sort
  collation silently bypassed the index, so use binary collation for sort keys
  and normalise at write time.
- Search: FTS on title, filled during import.
- Expect 300k+ rows per playlist. Benchmark import and browse on release
  builds with on-disk DBs (the Apple suite lives in `LumePerformanceTests`).

## Android TV / UX

- Compose for TV (`androidx.tv.material3`); Leanback is legacy.
- On Apple, **focus behaviour was the #1 source of rework**. Agree on a focus
  map per screen before coding, and verify it with real D-pad presses, not
  touch or emulator clicks. Full-width rows need full-width focus targets.
- Localise from day one in the same 10 languages (ar, en, de, es, fr, it, ja,
  ko, pt, zh-Hans). Consider generating `strings.xml` from the Apple String
  Catalog keys, so translations aren't paid for twice.

## Repo rules that carry over

- **No real channel or broadcaster names** in tests, comments, commits or PR
  text; use fictional ones ("Lume Sport 1", "Northbeam One"). The same applies
  to screenshots.
- **No Dolby word marks** in the UI or store copy. Use technical labels
  (`HDR10`, `DV P8.1`, `E-AC-3 JOC`).
- Never put stream URLs, tokens or credentials in logs or diagnostic exports.
- License: AGPL-3.0, like Lume, LumeRecorder and LumeCloud.

## Suggested first milestones

1. Gradle skeleton (phone + TV in one app module or split by form factor), CI
   running the `LumeCloud/spec` vectors.
2. Xtream + M3U catalog import into Room. Identity vectors green.
3. Media3 playback (live + VOD) with the fallback engine.
4. Lume Cloud join (pairing code) → pull playlists and user state → favorites
   and progress show up from an Apple device.
5. Play Billing for Android's own Lume Pro.
