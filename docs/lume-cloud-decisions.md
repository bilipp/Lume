# Lume Cloud — owner-confirmed decisions (app side, 2026-10-20)

## Sources of truth
- Plan: docs/lume-cloud-plan.md and docs/android-notes.md (in this worktree).
- Wire contract: ../LumeCloud/spec/PROTOCOL.md. It's normative.
- Kit: ../LumeCloud/LumeCloudKit (product LumeCloudKit). See its README for the actual API. It's a local SPM package like ../LumeRecorder/Kit. Never edit the Kit from this repo. If its API is insufficient, stop and report.
- Server: staging at https://cloud-staging.getlume.org (built separately), production at https://cloud.getlume.org.

## General
- Lume Cloud is FREE. There is no Pro gate, no crown, no PremiumBadge. PremiumManager state never enters a payload or SyncedBackendChoice.
- One backend per device: iCloud | Lume Cloud | Off. **iCloud stays the DEFAULT.**
- Users switch to Lume Cloud **only in Settings ▸ Sync**. There is NO "Join Lume Cloud" entry in LoginView or the first-run flow.
- Storage is EU-only (server side). No Stremio anywhere.
- CloudSyncEngine and CloudSyncMerge stay the reconciler. The transport only syncs the mirror store with the server.

## Answers to the discovery questions (numbered as in the discovery report)

1. **Switching is LIVE.**
   - Hot-swap the mirror container in the engine, ProfileManager, SportsFollowService and RecordingServerConfigService (`repoint(container:)`).
   - No relaunch.

2. **"Off" is PER DEVICE.**
   - It's not written to SyncedBackendChoice.
   - A device set to Off is NOT auto-joined when another Apple device enables Lume Cloud.
   - Off does not need to stop CloudKit mirroring of the CloudUserData container: keep the container open (it carries SyncedBackendChoice) and simply don't reconcile against any mirror.

3. **On every switch, copy mirror-only data from the old mirror into the new one** before the first reconcile, as a union. That covers all profiles, sports follows, paired recording servers, and the UserContentState of non-active profiles.

4. **Rejoining a backend:**
   - **Lume Cloud:** wipe the Lume Cloud mirror and bookkeeping (since=0) and re-pull from the server, then seed per #3.
   - **Returning to iCloud:** union-merge with the dormant iCloud mirror. Never wipe it, because a wipe would push deletions to CloudKit. Accept that items deleted meanwhile may come back.

5. **Conflict rule for profiles, sports follows and recording servers:**
   - The newest `updatedAt` wins (last write wins, like playlists). On an exact tie, the server/remote wins.
   - `UserProfile.isChild`: **true always wins** in a conflict.
   - Pin these rules in merge vectors.

6. **Turning on Lume Cloud with no stored account:** always ask "Create new account" or "Join with a code". Never create one silently.

7. **iCloud stays default; no Join entry in LoginView or first run.**
   - Exception (decision #7 of the plan): a fresh Apple device whose Apple ID already has SyncedBackendChoice = lumecloud (and the same server URL, see #12) auto-joins.
   - In that case the launch gate waits for the first Lume Cloud pull, up to 15 s, like the iCloud initial-sync gate. Never block forever, and never show the add-playlist form before that pull lands or times out.

8. **Recovery key:**
   - Shown when an account is created, with "I've saved it" and "Later". "Later" leaves a badge on Settings ▸ Sync until the key has been viewed.
   - Copy and Share are allowed on iOS, macOS and visionOS.
   - tvOS shows the key and its QR only after a "This will be visible on your TV" confirmation.
   - Restoring from a recovery key is supported on all platforms.

9. **Pairing QR** encodes `lume://cloud/pair?code=<6 digits>`.
   - Register and handle that deep link (DeepLink.cloudPair) → open the add-device pairing flow with the code prefilled.
   - No in-app camera scanner and no camera permission.
   - **tvOS ignores the link** (fix round): it has no camera to scan a pairing QR with, so Apple TV adds a device only by typing the code in Settings ▸ Sync ▸ Add a Device.
   - **iOS, macOS, visionOS:** the link is queued on `DeepLinkRouter` and the add-device sheet is presented from the browse root once nothing it can't be presented over is up. Settings, the playlist-sync sheet and Downloads are dismissed first; a player (not on macOS, where it has its own window), a paywall, the sync cover, a playlist/profile switch or a root alert is waited out. A presentation that never appears (another screen's own sheet) is retried, never dropped. While waiting or shown it counts in `AppStoreReviewPrompt.isScreenBusy`, so the root notices defer.

10. **While active:**
    - **404 account_deleted:** every Apple device returns to iCloud. Write SyncedBackendChoice = icloud when CloudKit is available, else this device goes Off. Clear the synchronizable Keychain root key. Keep local data. Show a notice.
    - **401 device_revoked:** only THIS device switches to Off. Keep local data and show a notice. Clear this device's stored credentials.

11. **Root key:** primary storage is a synchronizable data-protection Keychain item (AfterFirstUnlock, service "lume.cloud"). SyncedBackendChoice also carries it, with `rootKey` as `@Attribute(.allowsCloudEncryption)`. If they disagree, **SyncedBackendChoice wins**.

12. **Server URL is NOT user-configurable in the UI.**
    - It comes only from the app's environment/build config: an Info.plist key injected like the other `.env` values via Scripts/inject-env.sh, with a sensible default.
    - Debug builds default to staging `https://cloud-staging.getlume.org`; Release builds default to production `https://cloud.getlume.org`. An env override is allowed.
    - SyncedBackendChoice records the serverURL. A device **auto-joins only if the record's serverURL equals its own configured URL**; otherwise it ignores the record. That way debug and release accounts never mix.

13. **SIDE_LOAD builds** (no CloudKit): hide the iCloud option, so only Lume Cloud and Off are shown. Never touch SyncedBackendChoice or CKContainer there.

14. **One-time notice:**
    - Text: "Sync moved to Lume Cloud", including "Update Lume on your other devices".
    - It's a root alert behind an @AppStorage flag, shown once and deferred while the player is presented.

15/16. **Settings naming:**
    - Rename the Settings "iCloud" category to "Sync" on every platform. Keep the enum case. "iCloud" remains the name of the iCloud option.
    - Icon: SF Symbol `arrow.trianglehead.2.clockwise.rotate.90.icloud.fill`. Verify that it exists at the iOS 18 / tvOS 18 / macOS 15 / visionOS 2 deployment targets; if it doesn't, use the closest available `arrow.triangle.2.circlepath*` variant and note it.
    - **tvOS:** one rail category with in-place drill-ins, three radio rows (iCloud / Lume Cloud / Off), each change confirmed with an alert.
    - **APPROVED tvOS focus map:**

      ```
      Settings ▸ Sync (focus enters on the ACTIVE backend row)
       ├─ ◉ iCloud / ○ Lume Cloud / ○ Off   ← three full-width rows, Select → confirm alert
       ├─ Status (read-only, not focusable)
       ├─ Sync Now (iCloud and Lume Cloud; added 2026-10-22)
       └─ when Lume Cloud is active:
           ├─ Add a Device   → code entry → confirm → Menu returns to this row
           ├─ Devices        → list (Select = remove alert, no .contextMenu) → Menu returns here
           ├─ Recovery Key   → "visible on TV" confirm → key + QR → Menu returns here
           ├─ Leave Lume Cloud (destructive)
           └─ Delete Account   (destructive)
      ```

      The new-device pairing screen (Join with a code) shows a large code and QR, and Cancel is the only focusable item.
    - There is NO Advanced/server-URL row (see #12).

17. **Device name:** an editable name field, prefilled with the generic model name ("iPhone", "iPad", "Mac", "Apple TV", "Apple Vision Pro"). No user-assigned-device-name entitlement.

18. **Device list:**
    - Shows platform and last seen.
    - This device can't revoke itself; use Leave.
    - The Leave warning lists the devices with platform `android`/`androidtv`, by name.

19. **Delete account:**
    - A single destructive confirmation with clear text.
    - If the server is unreachable, show an error. Don't queue the deletion.
    - Available on all platforms, including tvOS.

20. **Child profiles:** Settings ▸ Sync requires the parental PIN while a child profile is active and a PIN is set.

21. **Diagnostics export and logs:**
    - Include the backend, its state, the last sync time, the last error, and the server type (official / staging / custom).
    - NEVER include the accountId, the deviceId, the root key, the authKey, the recovery key, pairing codes, Bearer headers, payloads or credentials.
    - Add a "Bearer" pattern to LogRedaction.

22. **Errors:**
    - 507: stop pushing, keep pulling, and show it in the status line.
    - 429: show "Lume Cloud is busy. Sync will retry automatically." and back off per Retry-After.
    - 413 record_too_large: skip that record and log it (redacted).
    - The first multi-batch upload shows "Uploading x of y" in the status line.

23. **No counts in sentences.** List device names instead. No plural variations in the catalog.

24. **Privacy wording:** "End-to-end encrypted" in the Lume Cloud section footer and the create/join flow. Data is stored in the EU, but the app doesn't say so (owner, 2026-10-22). App Store metadata is NOT changed in this PR.

25. **"Lume Cloud" stays in Latin script** in all 10 languages.

26. **No invite-code field.** `signup_closed` only shows an error message.

27. **The app builds against the real ../LumeCloud/LumeCloudKit**, which exists by the time implementation starts.
    - The LumeCloud GitHub repo is being made PUBLIC, so sideload CI checks it out like LumeRecorder: add a `CLOUD_REF` env and dispatch input pinned to `main` for now, plus an actions/checkout step for bilipp/LumeCloud into `LumeCloud`. No token needed.

## Approved technical assumptions
- Each pass runs pull → engine.reconcile → push, serialized behind the coordinator's isReconciling/pendingReconcile guard. The 600 ms debounce stays.
- Logical keys and types exactly per PROTOCOL.md §3. A nil profileID becomes "none".
- **Shadow namespaces:**
  - The existing `cloudsync.shadow.*.v1` keys become the `.icloud` namespace, with no migration. Lume Cloud uses `cloudsync.lumecloud.shadow.*.v1`.
  - Every backend switch (join, auto-join, Leave, Delete, revoke→Off→later rejoin) calls a new `CloudSyncShadow.resetAll()` on the TARGET namespace, which also clears the PIN and LiveTV baselines, before the first reconcile against the target mirror.
  - `reset()` keeps its current behaviour.
- **Stores:**
  - `LumeCloudUserData.store` holds the mirror models (minus SyncedBackendChoice) plus the bookkeeping models LumeCloudRecordState (unique rid, logicalKey, type, version, lastSyncedPayload, isDirty, isDeletionPending, plus undecodableCiphertext/seq for held records) and LumeCloudSyncMeta (nextSeq, accountId, historyToken).
  - It's one container and one file, with `cloudKitDatabase: .none`, `groupContainer: .none` and StoreRelocation.
  - historyPurgeIsSafe and StorageManager.catalogStoreURL exclude it.
- **Safety gate:** if the mirror is empty but synced records have no recorded deletion behind them (a lost store), reset the bookkeeping (since=0) and pull; never push tombstones for it.
  - Exception: a mirror emptied by the user's own recorded deletions is not a lost store, and its tombstones push normally.
  - A store-loss reset keeps recorded deletions that haven't reached the server, so the pull can't bring them back.
  - LocalCatalogReadiness applies too.
- **Unknown data:**
  - Unknown payload fields in a known type are kept in lastSyncedPayload and written back on push.
  - A record that doesn't open (unknown type, unsupported envelope version, undecodable payload) is held as raw ciphertext on its LumeCloudRecordState and retried on every pull. It's never pushed over or deleted.
  - Never add fields to mirror models.
- **Dirty detection** compares canonical payloads (sorted keys, epoch-ms dates, uppercase UUIDs).
- **Transport context and triggers:** the transport uses its own background ModelContext with no per-save sync. Triggers stay launch, foreground, remote change, content-sync complete, and the background flush under BackgroundActivity.perform.
- **Mirror-changed notification:** after applying a pull, post `Notification.Name.lumeSyncMirrorDidChange`. ProfileManager, SportsFollowService and RecordingServerConfigService refresh on it as well as on `.NSPersistentStoreRemoteChange`.
- **The iCloud CloudUserData container stays open** while Lume Cloud is active (for SyncedBackendChoice). Its events are scoped to ICloudBackend and never reconcile the Lume Cloud engine.
- **SyncedBackendChoice** is in the iCloud schema only and is a singleton deduped by changedAt. It's never bound to @Query and only used when `isCloudKitEnvironment` is true. CD_SyncedBackendChoice must be deployed to CloudKit Production before release; note this in CLAUDE.md.
- **WebSocket poke** runs only while scenePhase is .active and only triggers a pull.
- **Deletions:** user deletions of playlists and profiles go through the coordinator facade and push explicit tombstones. They're never inferred. Playlist removal still uses PlaylistDeletion.
- **Layering:** views talk only to the CloudSyncCoordinator facade, and only the service layer imports LumeCloudKit.
- **Retries:** retry and backoff (at most 3 conflict rounds) live in the app transport; the Kit never retries.
- **Spec vectors:** written to ../LumeCloud/spec/vectors only with `LUME_EXPORT_VECTORS=1` (TEST_RUNNER_ prefix via xcodebuild). Otherwise the tests drift-check, and skip when the sibling is absent.
- **Tests:** no live network calls in default test or UI-test runs. `-ui-testing` keeps LumeCloudBackend inert.
- **Localization:** all new strings ship in 10 languages (ar, de, en, es, fr, it, ja, ko, pt, zh-Hans) as translated. Codes and keys render LTR with Western digits and are spelled out for VoiceOver.
- **Repo rules:** fictional names only in tests and fixtures (no real channel or broadcaster names). Never log secrets. Mark DTOs, the codec, Values structs and the Keychain store nonisolated (default MainActor isolation).
- **No git:** no commits, no pushes.

## The actual LumeCloudKit API (built; read ../LumeCloud/LumeCloudKit/README.md and the sources for details)

**Keys and payloads**
- `LumeCloudKeys(rootKey:)` / `.generate()`
  - `authVerifier`, `authToken`, `recordID(for:)`
  - `seal(_ payload: LumeCloudPayload) -> (rid, ciphertext)`, `openPayload(_:rid:)`, `open`/`seal` on raw bytes
- `LumeCloudRecoveryKey.encode(_ keys:)`, `.decode(_:) -> Data`, `.keys(from:)`
- `JSONValue` (with `canonicalJSON()`)
- `LumeCloudPayload {v, type, key, data, extra}`: `encoded()` is canonical RFC 8785; `decode(_:)`.
  - Store bookkeeping on the `encoded()` bytes.

**Pairing**
- `LumeCloudGrant {accountId, rootKey, serverURL}`
- `SealedGrant {enc, ciphertext}`
- `LumeCloudPairing.makeKeyPair()`, `.seal(_:to:code:)`, `.open(_:privateKey:code:)`

**Client**
- `LumeCloudClient(baseURL:session:credentials:)` with `Credentials(accountId:keys:deviceID:)`
- Methods:
  - `withCredentials`, `createAccount(authVerifier:invite:)`, `account()`, `deleteAccount()`
  - `registerDevice(id:name:platform: LumeCloudPlatform)`, `devices()`, `revokeDevice(id:)`
  - `changes(since:limit:)`, `allChanges(since:limit:)`
  - `push([PushRecord])`, where records are `PushRecord.upsert(rid:baseVersion:ciphertext:)` / `.delete(rid:baseVersion:)`; results are `PushResult .ok / .conflict(rid:current: RemoteRecord)`
  - `startPairing`, `pairingRequest(code:)`, `sealPairing(code:sealed:)`, `pairingResult(code:pollToken:)` (`.pending` / `.sealed`)
  - `health()`, `events() -> AsyncThrowingStream<Int, Error>`
- `LumeCloudPlatform` is an open string struct with `.current`.

**Errors**
- `LumeCloudError`: `.badRequest(message:)`, `.badAuth`, `.deviceRevoked`, `.signupClosed`, `.accountDeleted`, `.notFound`, `.pairingAlreadySealed`, `.resyncRequired`, `.recordTooLarge`, `.rateLimited(retryAfter:)`, `.quotaExceeded`, `.server(status:code:)`, `.transport(URLError)`, `.decoding(String)`, `.missingCredentials`.
- `LumeCloudCryptoError` is separate: `unsupportedEnvelopeVersion` → skip the record and keep it.
- After `events()` fails with `.badAuth` / `.notFound`, call `changes` to get the precise code.

**Other**
- `LumeCloudAPI` holds the official and staging URLs and limits.
- The Kit never retries or reconnects. Backoff, conflict rounds and socket reconnects belong to the app transport.
- HPKE needs no `#available` check at our deployment targets.

## Server facts (staging is live at https://cloud-staging.getlume.org)

- **Push `nextSeq` is NOT a cursor.** It's the next seq the server will assign.
  The transport advances its stored cursor ONLY from `/changes` responses
  (`allChanges`), whose `nextSeq` = the highest seq returned.
- **Echoes:** records this device pushed come back on the next pull. They're
  no-ops when the payload equals `lastSyncedPayload`, so they must not cause
  dirty loops.
- **Socket poke:** `seq` = the highest assigned seq. Pull only when it's
  greater than the stored cursor.
- **Conflict on a never-existing record:**
  `current = {version:0, deleted:true, ciphertext:nil}`.
- **Other errors:** a missing `X-Lume-Device` → 400. `503 unavailable` may
  occur on pairing or account creation; show "try again".

## Kit and server update (LumeCloud af21f9a)

- **Kit folder:** now `../LumeCloud/LumeCloudKit`; the package and product are still `LumeCloudKit`. The pbxproj `relativePath` points there; the old symlink workaround is gone.
- **accountId is DERIVED from the root key:** `LumeCloudKeys.accountId`, HKDF info `lume-cloud/v1/account`, 22 chars.
  - Use `createAccount(keys:invite:)`; the old `createAccount(authVerifier:)` is deprecated.
  - Use `Credentials(keys:deviceID:)`.
  - New error `.accountExists` (409).
- **Restore from a recovery key:**
  1. `LumeCloudRecoveryKey.keys(from:)` → `keys.accountId`.
  2. Store the identity.
  3. `registerDevice` with a FRESH device UUID.
  4. Wipe the Lume Cloud mirror and bookkeeping, then pull from `since=0`.
- **Revoked device:** 401 `device_revoked` keeps the synchronizable Keychain identity. It belongs to the whole Apple ID, and other Apple devices are still valid members. This device goes Off and rotates its device UUID; rejoining requires pairing or recovery.

## Sync Now (owner, 2026-10-22)

- Settings ▸ Sync has a Sync Now row for iCloud AND Lume Cloud (hidden for Off), right under the status, on every platform.
- It calls `CloudSyncCoordinator.syncNow()`: that waits for an in-flight pass, then runs one immediately with `ReconcileReason.manual`, which skips the debounce and the "nothing pending" check.
- It's disabled without an iCloud account or a Lume Cloud membership.
- CloudKit's own import/export has no public trigger, so for iCloud it reconciles what's local.

