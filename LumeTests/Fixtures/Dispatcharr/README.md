# Dispatcharr DVR fixtures

Canned Dispatcharr **0.33.0** responses for the `DispatcharrBackend` tests.
All channel, programme and user names are fictional.

## Provenance — read this first

Each answer below is tagged:

- **[live]** observed against a local Dispatcharr 0.33.0 Docker container
  (`http://localhost:9191`) with real recordings running.
- **[source]** read from the Dispatcharr `v0.33.0` source
  (`apps/channels/api_views.py`, `apps/channels/tasks.py`,
  `apps/channels/serializers.py`, `apps/channels/signals.py`,
  `apps/channels/dvr_access.py`, `apps/accounts/authentication.py`,
  `apps/output/views.py`, `dispatcharr/settings.py`), both from the running
  container and from the `v0.33.0` tag on GitHub.

The fixtures were first written from source while the Docker engine was
hung; the behaviour of running recordings was then re-checked live (see the
**[live]** bullets in (a), (b), (c), (e) and (g)). Not observed live: the
XC/M3U output URL shapes, server-side padding (the test instance had zero
pre/post offsets) and AVPlayer itself. Where a fixture body is from source
rather than captured, the table says so.

## Loading fixtures in tests

`LumeTests` is a synchronized folder, so these files also end up in the test
bundle (that's why every file has a unique `dispatcharr-` prefix: bundle
resources are flattened). Don't load them through `Bundle`. Read them from
disk relative to the repo root with the `#filePath` helper in
`LumeTests/Helpers/TestHelpers.swift`:

```swift
func dispatcharrFixture(_ name: String, filePath: String = #filePath) throws -> Data {
    try Data(contentsOf: repoRootURL(filePath: filePath)
        .appendingPathComponent("LumeTests/Fixtures/Dispatcharr/\(name)"))
}
// let data = try dispatcharrFixture("dispatcharr-recordings.json")
```

`exampleDataURL`/`loadExampleJSON` point at the gitignored `ExampleData/`, so
don't use them for these committed fixtures.

## Files

| File | Endpoint | Provenance |
|---|---|---|
| `dispatcharr-version.json` | `GET /api/core/version/` | live |
| `dispatcharr-token.json` | `POST /api/accounts/token/` | live shape, fake JWTs |
| `dispatcharr-token-refresh.json` | `POST /api/accounts/token/refresh/` | source (`ROTATE_REFRESH_TOKENS=False` ⇒ only `access`) |
| `dispatcharr-users-me-admin.json` | `GET /api/accounts/users/me/` | live (api_key replaced) |
| `dispatcharr-users-me-dvr-manage.json` | ″ standard user, `dvr_access: manage` | source |
| `dispatcharr-users-me-dvr-view.json` | ″ standard user, `dvr_access: view` | source |
| `dispatcharr-users-me-standard-default.json` | ″ standard user, no `dvr_access` ⇒ view | source |
| `dispatcharr-users-me-dvr-none.json` | ″ `dvr_access: none` | source |
| `dispatcharr-users-me-streamer.json` | ″ `user_level: 0` ⇒ none, whatever `dvr_access` says | source |
| `dispatcharr-channels.json` | `GET /api/channels/channels/` (unpaginated) | source (serializer field list) |
| `dispatcharr-recordings.json` | `GET /api/channels/recordings/` | source (keys from `run_recording`) |
| `dispatcharr-recording-created.json` | `POST /api/channels/recordings/` → 201 | source |
| `dispatcharr-recording-stop.json` | `POST /api/channels/recordings/{id}/stop/` → 200 | source |
| `dispatcharr-error-400-end-in-past.json` | create with `end_time` in the past | source |
| `dispatcharr-error-400-field.json` | DRF field errors | DRF standard shape |
| `dispatcharr-error-401-missing.json` | no credentials | DRF standard |
| `dispatcharr-error-401-token-invalid.json` | expired/invalid Bearer JWT | simplejwt standard |
| `dispatcharr-error-401-bad-login.json` | `POST /api/accounts/token/` wrong password | simplejwt standard |
| `dispatcharr-error-401-bad-api-key.json` | unknown `X-API-Key` | source |
| `dispatcharr-error-403.json` | permission denied (e.g. view-only user POSTs) | DRF standard |
| `dispatcharr-error-403-playback.json` | `/file/` or `/hls/` without valid auth | source (`JsonResponse`, not DRF) |
| `dispatcharr-error-404.json` | unknown recording id | DRF standard |
| `dispatcharr-error-409-stop-terminal.json` | stop on completed/interrupted/failed | source |
| `dispatcharr-error-429.json` | login throttle (`login: 3/minute`) | DRF standard |
| `dispatcharr-error-429-api-key.json` | repeated bad API keys from one IP | source |

## Answers

### Auth (applies to everything)

- **[source]** The default authenticators are `JWTAuthentication` and then
  `ApiKeyAuthentication`. The API key goes in `X-API-Key: <key>` or
  `Authorization: ApiKey <key>`. Never send a Bearer header alongside the
  key: an invalid Bearer header fails with 401 before the key is looked at.
- **[source]** JWT: access 30 min, refresh **1 day**, no rotation. The refresh
  response is `{"access": …}` only. Once the refresh token expires, Lume has
  to log in again with the stored password. The `login` scope is throttled to
  `3/minute`.
- **[source]** Bad API keys are rate-limited per client IP. After the limit,
  the server returns 429 with `Too many API key attempts…`, so a wrong key
  must stop polling right away.
- **[live]** `POST /api/accounts/api-keys/generate/` returns
  `{"key": …, "user": {…}}` and replaces the user's single key. Lume must not
  call it (owner decision 1); it was used here only to set up the test
  instance.
- **[live] ⚠️ `GET /api/accounts/users/me/` returns the user's own
  `api_key` in plain text** (`null` when none has been generated). Never log
  or export that body. The admin fixture carries a fake key.

### (a) Creating a recording

- **[source]** Body (JSON). `channel` is the Dispatcharr channel **id**
  (int). Times are ISO-8601. A naive time is read as server time (UTC):

  ```json
  {
    "channel": 2,
    "start_time": "2026-10-25T20:00:00Z",
    "end_time": "2026-10-25T21:00:00Z",
    "custom_properties": {
      "lume_source_ref": "<opaque>",
      "program": {
        "title": "Harbour Lights",
        "description": "…",
        "start_time": "2026-10-25T20:00:00Z",
        "end_time": "2026-10-25T21:00:00Z"
      }
    }
  }
  ```

- **[source] Padding is applied server-side, but only when
  `custom_properties.program` is an object.** The serializer subtracts
  `dvr_pre_offset_minutes` from `start_time` and adds
  `dvr_post_offset_minutes` to `end_time` *before saving*. The stored and
  returned `start_time`/`end_time` are therefore the padded times (see
  `dispatcharr-recording-created.json`: 19:55–21:05 for a 20:00–21:00
  programme). The unpadded times survive in `custom_properties.program`.
  Match pending and active recordings on `program.end_time`
  (`ServerRecording.programmeEnd`), never on equal top-level times. A
  fixed-duration "record now" sends no `program` object, so it is not padded.
- **[source]** A `start_time` in the past is clamped to *now* (record now
  works by sending the programme start). An `end_time` in the past returns
  400 `{"non_field_errors":["End time must be in the future."]}`.
- **[source]** `custom_properties` must be an object. The keys `file_path`,
  `_hls_dir`, `file_name`, `file_url` and `output_file_url` are stripped from
  client input. Every other key is stored as given.
- **[live]** Created recordings with and without `program`: the response
  echoes `custom_properties` as sent; after the run `lume_source_ref` and
  `program` are still there next to the server's own keys. The server also
  adds `poster_url`/`poster_logo_id` from its artwork lookup.
- **[source] `lume_source_ref` survives the run.** `run_recording` re-reads the
  row (`refresh_from_db`) and copies only its own keys (`status`,
  `started_at`, `file_url`, `output_file_url`, `file_name`, `file_path`,
  `_hls_dir`, `program`, `poster_logo_id`, `poster_url`) into it. The
  finalizer adds `ended_at`, `bytes_written`, `remux_success`, `stream_info`
  and `interrupted_reason` to the same dict. Foreign keys are never dropped.
  `program` is enriched from EPG only when it has no `title`/`id`, so a
  programme Lume sends stays as sent.
- **[source]** A freshly created recording has **no `status` key** until the
  task starts (rule-generated rows carry `"status":"scheduled"`). Treat a
  missing status with a future `start_time` as scheduled.
  `custom_properties` itself can be `null` (row 18 in the list fixture).
- **[source]** The create needs `IsAdminOrDVRManager`, and the channel must be
  visible to the user (`_require_accessible_channel`; a hidden channel
  returns a 400 field error).

### (b) Playback endpoints

- **[source]** `/api/channels/recordings/{id}/file/` and
  `/api/channels/recordings/{id}/hls/<path>` both authenticate with
  `[JWTAuthentication, ApiKeyAuthentication, QueryParamJWTAuthentication]`,
  so they **accept `X-API-Key`, `Authorization: Bearer <JWT>` and
  `?token=<JWT>`**. `?token=` takes a JWT only, never an API key. API-key
  mode therefore has no query-string auth, which is why VLC is skipped in
  that mode.
- **[live]** Re-checked against the running instance on all three paths
  (`/file/`, `/hls/index.m3u8`, `/hls/<segment>.ts`) with an unknown id:
  no credential → 403 `{"error":"Forbidden"}`; `X-API-Key: <key>` → 404;
  `Authorization: Bearer <JWT>` → 404; `?token=<JWT>` → 404 (authenticated);
  `?token=<api key>` → 403; `?token=bogus` → 403. So the player sends the
  header to KSPlayer and LumeEngine, folds a password sign-in's JWT into
  `?token=` for VLC, and skips VLC for an API-key sign-in.
- **[source]** An invalid or expired `?token=` does not fail with 401. It
  leaves the request anonymous, and the view returns **403
  `{"error":"Forbidden"}`**, a plain Django `JsonResponse` rather than DRF's
  `detail` shape. A hidden recording also returns 403; a missing one
  returns 404.
- **[source] Segment URLs:** the `.m3u8` is rewritten so that every segment
  line is absolute (`<origin>/api/channels/recordings/{id}/hls/<seg>`).
  `?token=<JWT>` is appended to each segment **only if the playlist itself
  was requested with `?token=`**. With header auth, every segment request
  must carry the header again (`PlayableMedia.httpHeaders` covers this). The
  absolute URLs come from `build_absolute_uri_with_port(request)`, so they
  use the host and port Lume connected to.
- **[source]** `/file/` while the MKV doesn't exist yet → **302 to
  `/hls/index.m3u8`**, keeping `?token=` if present. `/hls/index.m3u8` after
  the HLS dir is gone and the MKV exists → **302 to `/file/`**. Either URL
  therefore converges, but redirects drop custom headers in some stacks, so
  choose by status: `recording` → HLS, anything finished → `/file/`.
- **[live]** With a running recording: `/hls/index.m3u8` → 200
  `application/x-mpegURL` with `X-API-Key`, Bearer JWT or `?token=<JWT>`;
  403 with no credential or `?api_key=`. The playlist is
  `#EXT-X-PLAYLIST-TYPE:EVENT`, 4 s H.264/AAC TS segments with absolute URLs;
  `?token=` is copied onto each segment only when the playlist was fetched
  with it. A segment needs the header again (403 without, 200 with). After
  the recording finished: `/file/` → 206 `video/x-matroska` for a ranged read
  (`Accept-Ranges: bytes`) with any of the three credentials, 403 without;
  `/hls/index.m3u8` → 302.
- **[source]** `/file/` supports `Range` (206 + `Content-Range`) and serves
  `video/x-matroska` for `.mkv`. The finished file is **MKV**, so AVPlayer
  can't play completed recordings.
- **[source]** HLS during recording: an `application/x-mpegURL` playlist with
  `video/mp2t` segments (~4 s, per the heartbeat comment). That is standard
  TS-HLS and *should* play in AVPlayer. Not verified live; keep AVPlayer off
  for Dispatcharr until checked. Every `.ts` fetch sets a 20 s Redis viewer
  heartbeat (`dvr:hls_viewer:{id}`).
- **[source]** Both endpoints also require `network_access_allowed(request,
  "STREAMS")`. If the server's network ACL blocks the client, they return 403
  `{"error":"Forbidden"}` even with valid auth.

### (c) `users/me` and DVR permissions

- **[live]** A `user_level: 1` user with `custom_properties.dvr_access:
  "view"`: `users/me` shows both fields; listing recordings → 200, a ranged
  `/file/` read → 206, any create → 403 `{"detail":"You do not have
  permission to perform this action."}`.

- **[live]** The shape is in `dispatcharr-users-me-admin.json`.
  `user_level`: `0` streamer, `1` standard, `10` admin.
- **[live]** `/api/accounts/permissions/` lists Django model permissions
  (`add_user`, …). It says nothing about DVR. Don't use it.
- **[source]** DVR access is derived, with no write probe needed
  (`apps/channels/dvr_access.py`):
  - `user_level >= 10` → **manage** (always).
  - `user_level == 0` → **none** (always, even if
    `custom_properties.dvr_access` is set).
  - `user_level 1..9` → `custom_properties.dvr_access` when it is one of
    `none`/`view`/`manage`, otherwise **view** (missing or unknown defaults to
    view).
  - list/retrieve/file/hls need view or manage. create/update/delete/stop/
    extend/comskip need manage.
- **[source]** Recordings and channels are also scoped per user: channel
  `user_level <= user.user_level`, `hide_adult_content`, and assigned
  `channel_profiles`. A non-admin can get 403 on a recording that exists.

### (d) `/api/core/version/`

- **[live]** `{"version":"0.33.0","timestamp":null}`. It is `AllowAny`, so it
  answers without credentials and is the reachability probe. `timestamp` is
  nullable.

### (e) Cancel scheduled vs stop running vs delete

- **[source]** `DELETE /api/channels/recordings/{id}/` → 204. It deletes the
  row (revoking the Celery task), notifies over websocket, then tears down
  any DVR client and **deletes the files** in a background thread. On a
  running recording that discards the partial content; on a scheduled one it
  is the cancel.
- **[source]** `POST /{id}/stop/` → 200 `{"success":true,"status":"stopped"}`.
  It writes `status: "stopped"` + `stopped_at` synchronously, then stops the
  stream in the background. The finalizer remuxes what was captured into the
  MKV and keeps `status: "stopped"`. Stop on
  `completed`/`interrupted`/`failed` → **409**
  `{"success":false,"error":"Recording is already <status>"}`. Stop on a
  scheduled row that hasn't started also "works": the task exits on start
  without connecting and leaves a `stopped` row with no file. Use DELETE for
  scheduled rows.
- **[live]** DELETE on a scheduled row → 204, then GET → 404. Stop on a
  running recording → 200 `{"success":true,"status":"stopped"}`; it finalizes
  as `status: "stopped"` with `remux_success: true` and a playable MKV, and
  keeps the original `end_time` (use `ended_at` for when it stopped). Stop on
  a `completed` or `interrupted` row → 409 `{"success":false,"error":"Recording
  is already completed"}`. Stop on a not-yet-started row → 200 `stopped`.
  DELETE on a running/interrupted row → 204.
- **[source]** Both need DVR manage (403 otherwise). 404 for an unknown id.

### (f) Xtream / M3U output → channel id

- **[source]** XC `player_api.php?action=get_live_streams`: `"stream_id":
  channel.id`. **`LiveStream.streamId == Dispatcharr channel id`.**
- **[source]** M3U output URLs depend on how the playlist was fetched:
  - `/output/m3u` (plain) → `http(s)://<host:port>/proxy/ts/stream/<channel
    uuid>` (+ optional query string).
  - `get.php?username=…&password=…` (XC-style M3U) →
    `http(s)://<host:port>/live/<user>/<pass>/<channel id>`. This is
    **id-based**: parse the last path component as an int, no uuid lookup.
  - `direct=true` (admin) → raw provider URLs: unmappable, Record hidden.
- **[source]** `GET /api/channels/channels/` with neither `page` nor
  `page_size` is **unpaginated**: a plain JSON array of every visible channel
  (`id`, `uuid`, `name`, `effective_name`, `channel_number`, `logo_id`, …).
  With either parameter it is a DRF page (`count/next/previous/results` +
  `has_unassigned_epg_channels`). The one-GET-per-refresh uuid→id map uses
  the unpaginated form.
- **[source]** Channel logos: `/api/channels/logos/<logo_id>/cache` (served
  directly, no redirect).

### (g) Recording `custom_properties.status` values

Observed live: *(absent)* before start, `recording`, `completed`, `stopped`
and `interrupted` (an unreachable source gives `interrupted` with
`bytes_written: 0`, `remux_success: false` and `interrupted_reason:
"no_stream_data: …"`). `failed` and `cancelled` are from source only.

| value | written by | meaning for Lume |
|---|---|---|
| *(absent)* | POST without status | scheduled |
| `scheduled` | recurring/series rules | scheduled |
| `recording` | `run_recording` start | recording; `file_url` → `/hls/index.m3u8` |
| `completed` | finalizer, clean end | completed; `file_url` → `/file/` |
| `stopped` | `/stop/` endpoint (kept by finalizer) | completed **partial** (has `stopped_at`) |
| `interrupted` | finalizer / no stream data / server shutdown | completed partial when `bytes_written > 0` / `remux_success`, otherwise failed; reason in `interrupted_reason` (`no_stream_data: …`, `server_shutdown`, `hls_directory_removed`, …) |
| `failed` | not written by `run_recording` in 0.33.0 (only appears in stop's terminal set) | failed; synthetic row 17 in the fixture |
| `cancelled` | only in `recording_end` system events; a cancelled row is **deleted**, so it never appears in the list | — |

- **[source]** `started_at`/`ended_at` are `str(datetime.now())`, naive
  `YYYY-MM-DD HH:MM:SS.ffffff`. Django sets the process `TZ` to
  `TIME_ZONE = "UTC"`, so in 0.33.0 they are **naive UTC** in practice
  (confirmed live: `started_at` equals the `Z` start time), not
  the display zone (`DISPATCHARR_TIME_ZONE`). `stopped_at` is
  `str(timezone.now())` with a `+00:00` offset. Prefer the top-level
  `start_time`/`end_time` (aware, `Z`). Parse the naive stamps as UTC and
  treat them as best-effort.
- **[source]** Size and duration: there is no duration field. `bytes_written`
  (int) appears after finalize; `stream_info` is optional.

## Reproducing

Run `ghcr.io/dispatcharr/dispatcharr` with `DISPATCHARR_ENV=aio` on :9191,
create the first admin through `POST /api/accounts/initialize-superuser/`,
add a stream whose URL serves endless MPEG-TS (a paced HTTP server over an
`ffmpeg -f lavfi -i testsrc2` file works; a one-shot `ffmpeg -listen 1`
source does not survive the proxy's probing), make a channel from it with
`POST /api/channels/channels/from-stream/`, then create recordings against
that channel id.
