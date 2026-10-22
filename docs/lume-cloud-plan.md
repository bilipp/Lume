# Lume Cloud — platform-neutral sync (plan)

Status: proposal, updated 2026-10-20 with the owner's decisions. Goal: sync user
data between Apple devices and the Android app without iCloud, while iCloud
stays the default on Apple.

Companion doc: [`android-notes.md`](android-notes.md), which covers what the
Android app must match and what we learned building the Apple app.

## Decisions (2026-10-20)

| # | Decision |
|---|---|
| 1 | **The owner runs the official instance on Cloudflare** (Workers + Durable Objects, `cloud.getlume.org`). No NAS, VM or container. The server stays open source (AGPL-3.0), so anyone can deploy it to their own Cloudflare account. |
| 2 | **New repo `bilipp/LumeCloud`** (private for now) holds the server, the Swift client Kit, and the language-neutral spec. It's separate from LumeRecorder. |
| 3 | **Android = Kotlin/Compose** (`bilipp/LumeAndroid`). It shares *no code* with Apple. The spec, the JSON schemas and the test vectors in `LumeCloud/spec/` are the contract. |
| 4 | **Lume Cloud is free**, with no Pro gate on any platform. *(Revised the same day; it was briefly planned as Pro.)* |
| 5 | **Lume Pro is sold separately per store**: StoreKit on Apple, Play Billing on Android. There's no cross-platform unlock, and the server never handles purchases. |
| 6 | **No Stremio.** The `feat/stremio` branch is abandoned and deleted. |
| 8 | **EU-only storage.** Every Durable Object is created in the `eu` jurisdiction. The wire contract lives in `LumeCloud/spec/PROTOCOL.md`. |
| 7 | **On Apple, the backend choice applies to the whole Apple ID.** Other Apple devices **join automatically**, with a one-time notice and no prompt. See *Apple-wide backend choice*. |

## TL;DR

`CloudSyncEngine` already splits sync into two layers:

```
catalog (default.store) ⇄ CloudSyncEngine (3-way merge + shadow) ⇄ mirror (CloudUserData.store) ⇄ NSPersistentCloudKitContainer ⇄ iCloud
```

Only the last hop is Apple-specific. Lume Cloud is a **second transport for the
same mirror schema**. It has these properties:

- The server is end-to-end encrypted: it stores opaque, versioned blobs plus a
  change feed.
- The account is a key, not an email.
- Merging happens on the client, reusing `CloudSyncMerge`.
- Each device uses exactly one backend: **iCloud | Lume Cloud | Off**.
- It's free. The server never sees purchases, and Pro stays per store.

Alternatives were rejected in the first draft: CloudKit Web Services on
Android, Firebase/Supabase, user WebDAV/Drive journals, running iCloud and Lume
Cloud as a bridge, and merging on the server. The reasons haven't changed.

## What gets synced (unchanged scope)

Everything in the cloud schema in `LumeApp.makeCloudContainer`:

| Mirror model | Logical key (normative: `LumeCloud/spec/PROTOCOL.md` §3) |
|---|---|
| `SyncedPlaylist` (incl. credentials, MAC) | `playlist/<UUID>` |
| `UserContentState` | `content/<profileUUID>/<contentId>` |
| `UserProfile` | `profile/<UUID>` |
| `SyncedEPGSource` | `epgSource/<UUID>` |
| `SyncedParentalPIN` | `parentalPin` |
| `SyncedCategoryRestriction` | `categoryRestriction/<categoryID>` |
| `SyncedSportsFollow` | `sportsFollow/<profileUUID>/<key>` |
| `SyncedRecordingServer` (token) | `recordingServer/<UUID>` |
| `SyncedLiveTVPreferences` | `liveTVPrefs` |

The catalog never syncs; every device rebuilds it from the provider. Player
settings and the Trakt/Simkl/OpenSubtitles tokens stay device-local.

## `LumeCloud` repo layout

```
LumeCloud/
├── server/                     Cloudflare Worker (TypeScript): router + AccountDO / PairingDO / SignupGuardDO
│   ├── src/
│   ├── test/                   @cloudflare/vitest-pool-workers
│   ├── wrangler.jsonc          DO bindings + SQLite migrations, rate limits, route cloud.getlume.org
│   └── package.json
├── LumeCloudKit/               LumeCloudKit: zero-dependency Swift package (DTOs, crypto, HTTP, WebSocket),
│   ├── Package.swift           consumed by Lume as a local SPM package at ../LumeCloud/LumeCloudKit
│   └── Sources/ Tests/
├── spec/                       ← the cross-platform contract (Android consumes this)
│   ├── PROTOCOL.md             API, sync algorithm, error codes
│   ├── openapi.yaml
│   ├── payloads/*.schema.json  one JSON Schema per collection
│   └── vectors/
│       ├── identity.json       provider input → catalog id
│       ├── merge.json          (base, local, remote) → expected
│       ├── crypto.json         HKDF / HMAC / AES-GCM / HPKE known answers
│       └── payloads/*.json     canonical encoded records
└── .github/workflows/          server tests + deploy (staging on main, production on tag); Kit tests; spec drift check
```

- The vectors come **from the Swift app**. A `Lume` test target exports them,
  so the Apple implementation stays the reference, and a `LumeCloud` CI check
  fails if they drift.
- The exporter is `LumeTests/LumeCloudVectorExportTests` (one file per
  document). It builds `identity.json`, `merge.json` and `payloads/<type>.json`
  from the app's real helpers (`M3UIdentity`, `mediaServerHash`, the Stalker and
  Plex stream ids, `CloudSyncMerge` with every collection's conflict policy,
  `LumeCloudTransport.mergedPayload`, `LumeCloudPayloadCodec`). A normal test
  run drift-checks the committed files byte for byte and skips when
  `../LumeCloud` is absent. To regenerate after an intentional change, run the
  suite with `TEST_RUNNER_LUME_EXPORT_VECTORS=1` in the `xcodebuild test`
  environment, then commit the changed files in LumeCloud. Inputs are fixed and
  fictional, so the output is deterministic.
- `LumeAndroid` consumes `spec/` as a **git submodule** pinned to a tag, and
  its unit tests run every vector.
- `LumeRecorder` has the same need on Android. Its Kit is Swift-only, so the
  recorder API needs an `openapi.yaml` too before Android can do DVR.

## Architecture — Apple client

### Stores

- Add `LumeCloudUserData.store`. It uses the same cloud schema with
  `cloudKitDatabase: .none`. The active backend decides which mirror container
  `CloudSyncEngine` gets.
- Add `LumeCloudSyncState` (local-only): per record, the `rid`, the logical
  key, the server `version`, the last-synced payload (used as the merge base)
  and a dirty flag. **Don't add fields to the mirror models.** That would
  change the CloudKit schema for nothing.

### Components

- **`SyncBackend` protocol**, extracted from `CloudSyncCoordinator`. It covers
  account status, start/stop, pull, push and events. The CloudKit code moves
  into `ICloudBackend` with no behaviour change.
- **`LumeCloudTransport`**, a background actor:
  - **Pull:** `GET /changes?since=` → decrypt → upsert or delete mirror rows
    (with its own `ModelContext.author`) → update the sync state.
  - **Push:** diff the mirror against the sync state → encrypt →
    `POST /push` with `baseVersion`.
  - **On 409:** 3-way merge the local mirror, the server value and the
    last-synced base with the `CloudSyncMerge` value functions, then retry.
  - **Triggers:** the existing `ReconcileReason`s, in the order pull →
    reconcile → push. A WebSocket (`/v1/socket`) poke triggers a pull while in the foreground. No per-save sync,
    because main-thread saves hitch KSPlayer.
- **No Pro gate.** Lume Cloud is free on every platform, so there's no crown
  and no paywall.

### ⚠️ The shadow must be namespaced per backend

If we switch to an empty Lume Cloud mirror with the iCloud shadow still in
place, every item reads as `local=v, cloud=nil, shadow=v`. The engine treats
that as a cloud-side delete and **wipes local data**.

- Key the shadow by backend (`.icloud` / `.lumecloud`).
- Start the target backend's shadow **empty** on every switch, so the engine
  does a union merge and can't delete anything.
- `LocalCatalogReadiness` applies to both backends.

### Apple-wide backend choice

Without this, enabling Lume Cloud on the iPhone leaves the Apple TV on iCloud,
and the two stop seeing each other's progress.

- **New CloudKit model `SyncedBackendChoice`** (singleton) in the iCloud
  schema. Fields: `backend` (`icloud` | `lumecloud`), `serverURL`, `accountId`,
  `rootKey` (`.allowsCloudEncryption`), `changedAt`. It needs a CloudKit
  Production schema deploy before release.
- **Enable on any Apple device** → write the record. Every other Apple device
  on the Apple ID reads it on launch, foreground or a remote change, and **joins
  automatically**, without a pairing code (iCloud already proves it's the same
  person). It shows a one-time notice: "Sync moved to Lume Cloud". It joins
  with an empty Lume Cloud shadow, so whatever it did meanwhile on iCloud gets
  pushed, not lost.
- After the switch, iCloud carries only this one record. All user data goes
  through Lume Cloud.
- iCloud signed out, or CloudKit unavailable: no handoff. That device stays
  where it is and can still join manually with a pairing code.
- Pairing codes are only for devices outside the Apple ID (Android, or another
  person's Apple device).

### Leaving Lume Cloud (Apple side)

Lume Cloud is the only backend that reaches every device, so turning it off is
a deliberate action:

- The server's device list shows the platform of every device. If any device
  other than the Apple ID's own is on the account, warn first: "2 Android
  devices sync through this account; they'll stop syncing with your Apple
  devices."
- The choices are:
  - **Keep Lume Cloud** (the default).
  - **Leave:** `SyncedBackendChoice` = `icloud`. Every Apple device returns to
    iCloud with an empty iCloud shadow, so it can't delete anything. The
    account stays, and Android keeps syncing.
  - **Delete account:** wipe it on the server, then the same as *Leave* on
    Apple.
- **Android after a deletion:** the server returns a typed `account_deleted`
  error. Android says so, switches to local-only, and keeps its local data.
  After a *Leave*, Android notices nothing.
- Android can't write to iCloud, so only an Apple device can change the
  Apple-wide choice.
- Rejoining the same account later merges everything back, again starting from
  an empty shadow.

## Architecture — server (Cloudflare Workers + Durable Objects)

The official instance runs entirely on Cloudflare. There's no VM, container
or NAS. The server is **TypeScript** (Workers' native language). The server
shares no code with the clients anyway: it stores opaque blobs and never
decrypts or merges anything, so the Swift `Kit/` and Kotlin clients lose
nothing.

```
client ──HTTPS / WebSocket──▶ Worker "lume-cloud" (cloud.getlume.org)
                                │  auth header → accountId, rate limits, routing
                                ├──▶ AccountDO   (one per account, idFromName(accountId), own SQLite)
                                ├──▶ PairingDO   (one per pairing code, expires via alarm)
                                └──▶ SignupGuardDO (one per client IP, daily signup counter)
```

### Why Durable Objects fit

- **One `AccountDO` per account** gives each account its own embedded SQLite
  database. Every push, change-feed read and device operation for an account
  runs single-threaded in that object, so `seq`/`version` are strongly
  consistent without locks or transactions across machines.
- **Realtime pokes** use the **WebSocket Hibernation API**: the object sleeps
  while sockets stay connected, so idle connections don't accrue duration
  charges. `setWebSocketAutoResponse("ping","pong")` answers heartbeats
  without waking it. This replaces SSE, which would keep the object billed for
  as long as the stream is open.
- **Alarms** handle the inactivity purge and tombstone compaction per account.
  No cron job has to scan every account.
- **Backups come built in:** SQLite-backed objects support point-in-time
  recovery for any moment in the past 30 days (per object, through the PITR
  bookmark API). A restore runs per account, which matches how support
  requests arrive anyway.
- **Account deletion** is `ctx.storage.deleteAll()` plus `deleteAlarm()`.
  Once the data is gone, the object stops billing.

### `AccountDO` SQLite schema

```
meta     (key PRIMARY KEY, value)     -- auth_verifier, next_seq, used_bytes, record_count, last_seen_day
devices  (id PRIMARY KEY, name, platform, created_at, last_seen, revoked)
records  (rid PRIMARY KEY, version, seq, deleted, ciphertext BLOB, size, updated_at)
           INDEX records_seq ON records(seq)
```

- `seq` comes from `meta.next_seq` and is bumped inside the same synchronous
  storage transaction as the write.
- **Bump `last_seen` and re-arm the purge alarm at most once per day.** Each
  `setAlarm()` and each row write is billed, so doing this on every request
  would multiply writes for no benefit.

### Other objects

**`PairingDO`**, keyed by `idFromName(code)`:
- It holds `{accountId?, hpkePubKey, deviceName, platform, sealedPayload?}`,
  and an alarm deletes it after 10 minutes.
- Only the first sealed payload is accepted.
- If a code is already taken, the Worker draws a new one.
- Guessing a code gains nothing. An attacker can read a public key, but can't
  produce a valid sealed root key. The joined device also shows the new
  device's name and platform before it seals anything.

**`SignupGuardDO`**, keyed by client IP (IPv6 truncated to /64):
- It holds a daily counter for account creation.
- The Workers **Rate Limiting binding** is only available in 10 s / 60 s
  windows and counts per location. It handles burst limits (signups, pairing
  attempts, general requests per account). The DO handles the per-day signup
  cap.

### API (v1)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/accounts` | Create an account. The Worker generates a random 128-bit `accountId`, initialises the `AccountDO` with the auth verifier, and rate-limits per IP. |
| `DELETE` | `/v1/accounts/me` | Delete the account immediately (`deleteAll`). Required in-app by App Store 5.1.1(v) and Google Play. |
| `POST/GET/DELETE` | `/v1/devices` | Register, list or revoke devices |
| `GET` | `/v1/changes?since=<seq>&limit=500` | `{records, nextSeq, hasMore}`. A stale `since` → `410` → full resync. |
| `POST` | `/v1/push` | `[{rid, baseVersion, deleted, ciphertext}]`, each answered with `ok{version, seq}` or `conflict{current}` |
| `GET` | `/v1/socket` | WebSocket upgrade. The server sends `{"type":"seq","seq":N}` when the feed advances; the client sends `ping` every 30 s and gets `pong` (auto-response). |
| `POST/GET` | `/v1/pairings` | HPKE-sealed handoff of the account key to a new device |
| `GET` | `/healthz` | Health check |

Errors are JSON `{"error": "<code>"}` with these statuses: `401`
`bad_auth`, `404` `account_deleted`, `409` `conflict`, `410`
`resync_required`, `413` `record_too_large`, `429` `rate_limited`
(with `Retry-After`), and `507` `quota_exceeded`.

Tombstones are kept for 90 days. Records are capped at 64 KB. Push is batched
at up to 500 records or 4 MB per request.

### Repo `server/`

- TypeScript, configured through `wrangler.jsonc` (Durable Object bindings
  with `new_sqlite_classes` migrations, rate-limit bindings, and the custom
  domain route `cloud.getlume.org`).
- Vars: `SIGNUP=open|invite` and `INVITE_CODE` (a secret; for a private
  self-hosted instance).
- Tests use `@cloudflare/vitest-pool-workers`, which runs Durable Objects in
  the local runtime. That covers seq ordering, conflicts, quotas, alarms and
  hibernating sockets.
- PITR isn't available locally, so restores are tested on a staging Worker.
- Deploy with `cf`/Wrangler from CI on a tagged release. Use a separate
  `lume-cloud-staging` Worker on `cloud-staging.getlume.org`.
- **Self-hosting** means deploying the same repo to your own Cloudflare
  account (the free plan is plenty for a household) and entering that URL in
  the app. There's no Docker image. Running `workerd` on your own hardware is
  possible in principle but out of scope.

## Free service: abuse & cost controls

Lume Cloud is free, and the server knows nothing about purchases: no receipts,
no store APIs, no webhooks. Lume Pro stays a per-store thing inside each app
(see *Pro is per platform* below).

With no purchase gate, the open signup endpoint is the abuse surface. Each user
holds only kilobytes, so cost is a non-issue at realistic scale. The real risk
is someone misusing the server as free blob storage, or flooding it with
accounts.

| Control | Proposed default |
|---|---|
| Record size | 64 KB per record |
| Account quota | 10 MB and 100k records. A heavy real user is well under 1 MB. Return `413`/`507` above that. |
| Account creation | Per IP (`CF-Connecting-IP`, IPv6 truncated to /64): a burst limit through the Rate Limiting binding, plus a daily cap (e.g. 10) in `SignupGuardDO` |
| Request rate | Per account and per IP, with `429` + `Retry-After` |
| Inactive accounts | Purged after 12 months with no device check-in. Every app launch with sync on counts as a check-in, so only abandoned accounts go. |
| Device attestation (optional, later) | App Attest (Apple) / Play Integrity (Android) on account creation, only if abuse actually shows up. It adds per-platform complexity, so don't build it up front. |

### Pro is per platform

Lume Pro stays **per store**: StoreKit on Apple (today's `PremiumManager`,
unchanged) and Play Billing on Android. They're separate purchases with no
cross-platform unlock and no server involvement. Nothing in the sync payloads
carries purchase state. Never put `PremiumManager` state into a synced record,
or a Pro purchase would leak across the store boundary.

A setting that *configures* a Pro feature (e.g. combined-playlist config on
`SyncedPlaylist`) still syncs as plain data. Each platform decides locally
whether the feature behind it is unlocked.

## Crypto & accounts

All algorithms are chosen to exist natively on both platforms: CryptoKit on
Apple, and JCA plus Tink on Android.

- **Root key:** 32 random bytes, generated on the first device.
- **Derived keys:** HKDF-SHA256 with salt = empty and `info` =
  `"lume-cloud/v1/enc"`, `"…/id"`, `"…/auth"` → 32 bytes each.
- **Record id:** `rid = base64url-nopad(HMAC-SHA256(idKey, utf8(logicalKey)))`.
- **Record envelope:** `0x01 | nonce(12) | AES-256-GCM ciphertext | tag(16)`,
  with AAD = `utf8(rid)` and a fresh random nonce per write.
- **Payload:** UTF-8 JSON, keys sorted, matching the
  `spec/payloads/*.schema.json`.
- **Auth:** `Authorization: Bearer base64url(authKey)`. The server stores
  `SHA-256(authKey)`.
- **Account id:** server-assigned and opaque.
- **Pairing** uses HPKE (RFC 9180): DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
  AES-256-GCM. CryptoKit has `HPKE` (iOS 17+) and Tink has HPKE.
  1. The new device posts its HPKE public key, and the server returns a 6-digit
     code that expires after 10 minutes.
  2. The user types the code on a joined device, which shows the new device's
     name and platform for confirmation.
  3. That device seals `{serverURL, accountId, rootKey}`.
  4. The new device polls, receives the sealed payload and opens it.

  A QR code is a shortcut for phones.
- **Key storage:** Keychain on Apple (`kSecAttrSynchronizable`, so iCloud
  Keychain carries it to other Apple devices) and an Android Keystore–wrapped
  key in DataStore.
- **Recovery:** a Crockford-base32 rendering of the root key plus a QR code,
  under Settings ▸ Lume Cloud ▸ Recovery key. If every device is lost and
  there's no backup, the synced state is gone, and the UI says so.
- `crypto.json` known-answer vectors pin every step above. The Kotlin
  implementation is "done" when it reproduces them.

## Hosting the official instance (Cloudflare)

- **Account:** the owner's Cloudflare account. **Domain:** `cloud.getlume.org`
  (the `getlume.org` zone is already on Cloudflare), with
  `cloud-staging.getlume.org` for staging. TLS, DDoS protection and global
  anycast come with it.
- **Plan:**
  - The **Workers Free** plan covers development and a small beta. Its daily
    limits **fail hard** when exceeded instead of billing: requests error out
    until 00:00 UTC.
  - Switch to **Workers Paid** (from $5/month) before public launch.
  - For SQLite-backed Durable Objects, Paid includes 25 billion row reads and
    50 million row writes per month, and 5 GB-month of storage, then
    $0.20/GB-month.
  - Each account is kilobytes to about 1 MB, so storage is negligible. The
    real drivers are requests and row writes, which the once-a-day
    `last_seen` rule and batched pushes keep small.
  - Set a billing alert and watch the Durable Objects dashboard (it charts
    storage per namespace).
- **Backups:** Durable Object PITR, 30 days per account. No backup jobs are
  needed. Document the restore runbook in `server/README.md`, and test it on
  staging.
- **Logs:**
  - Turn on Workers Logs with sampling.
  - Never log request bodies, auth headers, root keys or ciphertext.
  - Don't log IP addresses beyond what Cloudflare keeps by default, and keep
    the retention short.
- **GDPR:**
  - Cloudflare is the processor. Sign Cloudflare's DPA (it's in the
    dashboard).
  - The owner is the controller for account metadata: device names, and IP
    addresses at Cloudflare's edge. There are no emails and no purchase ids.
  - Update the privacy policy, the App Store privacy labels (likely
    *Identifiers*, used for app functionality) and the Google Play Data safety
    form.
  - If EU-only storage is ever needed, Durable Objects support a jurisdiction
    restriction (`newUniqueId({jurisdiction: "eu"})` / jurisdiction-scoped
    namespaces). Decide this **before** launch, because existing objects don't
    move.
- **Push (v2):** the Worker can send FCM HTTP v1 messages. Check that a Worker
  can reach APNs (it requires HTTP/2 and token auth) before relying on silent
  push for Apple. Until then, WebSocket pokes in the foreground plus
  launch/foreground pulls are enough.

## Phases

| # | Deliverable | Where |
|---|---|---|
| 0 | **Spec v1**: `PROTOCOL.md`, OpenAPI, payload schemas. Vector exporters in Lume tests: identity, merge, payloads. Crypto vectors. | Lume + LumeCloud |
| 1 | **Client refactor**: `SyncBackend`, `ICloudBackend`, per-backend shadow (migrate the existing one to `.icloud`), hidden backend setting. `CloudSyncTests` stays green. | Lume |
| 2 | **Server MVP** on Workers + Durable Objects: accounts, devices, changes, push, WebSocket pokes, pairing, quotas, rate limits, alarms. vitest-pool-workers tests. Deployed to `cloud-staging.getlume.org`. | LumeCloud |
| 3 | **LumeCloudKit + transport** behind a flag: mirror store, sync state, crypto, Keychain, pull/push/conflict, signposts. | LumeCloud/LumeCloudKit + Lume |
| 4 | **UX**: Settings ▸ Sync (iCloud / Lume Cloud / Off), create or join via code/QR, device list + revoke, recovery key, delete account, status/diagnostics (no keys, tokens or credentials in logs or exports). 10 languages. tvOS focus map approved first. | Lume |
| 5 | **Switching & migration**: iCloud → Lume Cloud seeds from local state into an empty shadow. `SyncedBackendChoice` handoff with automatic joining on all Apple devices. Leave/Delete flow with a warning about other platforms. The iCloud mirror stays dormant, so switching back is a union merge. | Lume |
| 6 | **Beta on `cloud.getlume.org`** (Workers Free), then hardening: compaction + `410`, inactive-account purge, batched first upload, PITR restore runbook. | LumeCloud |
| 7 | **Android** joins via the same spec. | LumeAndroid |
| 8 | **Switch to Workers Paid** before public launch, add a billing alert, decide the EU jurisdiction. Silent push (v2). | ops |

## Risks & gotchas

- **Shadow reuse across backends wipes data.** This is the highest-severity
  risk; see above.
- **Device clocks are never authoritative.** Server `seq`/`version` decide;
  `updatedAt` is only a tie-break.
- **The transport runs on a background actor** with its own context, never on
  the main context during playback.
- **Credentials, recorder tokens and the root key** never appear in logs,
  diagnostic exports or server logs.
- **App ↔ Kit ↔ server ↔ spec version skew.** Pair commits as with LumeEngine
  and LumeRecorder. Add `CLOUD_REF` to the sideload CI next to
  `ENGINE_REF`/`RECORDER_REF`.
- **Spec changes are additive only within `v1`.** Removing or renaming a field
  needs `v2` and a migration window, because old app versions stay in the
  field for months.

## Still open

- **EU jurisdiction for Durable Objects:** yes or no, decided before launch,
  because existing objects can't move.
- **Quota and rate-limit numbers** in *Free service: abuse & cost controls*
  are proposals. Measure real accounts during the beta before fixing them.
