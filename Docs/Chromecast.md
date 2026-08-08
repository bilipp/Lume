# Chromecast integration

Lume bundles the **Google Cast SDK** (v4.8.4, dynamic XCFramework) so Chromecast
works out of the box on **iOS / iPadOS**. The Cast SDK has no macOS, tvOS, or
visionOS build, so it is linked with an `ios` platform filter and all Cast code
is gated behind `#if canImport(GoogleCast)` — the other platforms compile exactly
as before. This complements the native **AirPlay** support, which needs no
third-party SDK.

## Where it lives

| Piece | Path | Role |
|---|---|---|
| Vendored SDK | `Vendor/GoogleCast/GoogleCast.xcframework` | Google Cast SDK v4.8.4 (dynamic); linked + embedded on iOS only (`platformFilter = ios`) |
| Casting seam | `Lume/Services/Player/CastService.swift` | `CastProvider` protocol (session + transport + failure surface) + `configureGoogleCast()` registration |
| Castability rules | `Lume/Services/Player/CastCompatibility.swift` | what a receiver can be asked to play, and the MIME type to declare; pure + unit-tested |
| Provider | `Lume/Services/Player/GoogleCastProvider.swift` | `GCKSessionManager` / `GCKRemoteMediaClient` bridge; loads the current `PlayableMedia`, exposes play/pause/seek and polled position/duration/state, reports refusals |
| Cast button | `Lume/Views/Player/ChromecastButton.swift` | `GCKUICastButton` styled to match the overlay |
| Casting UI | `Lume/Views/Player/ChromecastPlaybackView.swift` | stands in for the local engine while a session is active; drives the receiver's transport and polls its playhead into the shared `PlaybackClock` |
| Launch hook | `Lume/LumeApp.swift` | calls `CastService.shared.configureGoogleCast()` |
| Session → load hook | `Lume/Views/Player/FullScreenPlayerView.swift` | `loadOntoReceiver()` casts the stream on session connect, on player open with a session already active, and on mid-cast media/resolve changes; on session end the local engine resumes at the receiver's position |
| Discovery keys | `Lume/Info.plist` | `NSBonjourServices`, `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription` |
| Usage-description strings | `Lume/InfoPlist.xcstrings` | localizes the two usage descriptions (all catalog languages) |

The XCFramework carries its own `PrivacyInfo.xcprivacy`, so its required-reason
API and data-use declarations are covered without editing Lume's manifest.

## Project wiring (already done)

The `xcodeproj` wiring was applied by `Scripts`-style automation, but for
reference it is: a file reference to `Vendor/GoogleCast/GoogleCast.xcframework`,
added to the **Lume** target's *Frameworks* (link) and an *Embed Frameworks* copy
phase with **Code Sign On Copy**, both with `platformFilter = ios`. The
*Embed Frameworks* phase is ordered **before** the "Inject .env secrets" run
script to avoid a build-phase dependency cycle. Build settings gained
`FRAMEWORK_SEARCH_PATHS = $(PROJECT_DIR)/Vendor/GoogleCast` and `-ObjC` in
`OTHER_LDFLAGS`.

## Receiver app ID

Uses Google's Default Media Receiver (`kGCKDefaultMediaReceiverApplicationID`,
id `CC1AD845`). To use a styled/custom receiver from the
[Google Cast Developer Console](https://cast.google.com/publish), change the id in
`CastService.configureGoogleCast()` **and** the `_CC1AD845._googlecast._tcp`
entry in `Info.plist`.

## Updating the SDK

Download a newer dynamic XCFramework and replace the vendored copy:

```bash
curl -L -o gcast.zip \
  "https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-<version>_dynamic.zip"
unzip gcast.zip
rm -rf Vendor/GoogleCast/GoogleCast.xcframework
cp -R GoogleCastSDK-ios-<version>_dynamic_xcframework/GoogleCast.xcframework Vendor/GoogleCast/
```

Update `Vendor/GoogleCast/VERSION.txt`. No project changes are needed unless the
framework layout changes.

## How a cast session behaves

While a Chromecast session is active, `FullScreenPlayerView` unmounts the local
engine entirely (no double decode) and mounts `ChromecastPlaybackView` instead:
poster, receiver name, play/pause/±15s/scrubber that drive the receiver through
the `CastProvider` seam. The view polls the receiver's playhead into the shared
`PlaybackClock` every 500 ms (the Cast SDK pushes `GCKMediaStatus` only on
change), which keeps the scrubber live and — because the host persists watch
progress from that same clock at the usual boundaries — resume points and the
90%-watched flow keep working while casting.

## What a receiver will and won't play

A Chromecast fetches and decodes the stream itself, so it accepts far less than
the local engines do. That matters more here than in most apps because the host
*unmounts* the local engine for the cast — a receiver that never starts would
otherwise leave a poster and a frozen scrubber with nothing to explain it.

Two layers catch that, and the fallback for both is the same: keep the session
connected, play **this** stream locally, and show the "can't cast this stream"
notice. `castUnsupported` is keyed by media id, so moving to another title
retries; ending the session clears it.

1. **Before loading** — `CastCompatibility.evaluate(url)` refuses what is
   knowably unplayable: non-`http(s)` URLs (a downloaded `file://` movie, an
   unresolved `lumestalker://` placeholder) and containers the Default Media
   Receiver has no demuxer for (MKV, AVI, FLV, WMV, VOB, MPEG-PS, 3GP, …). It is
   deliberately conservative: an unrecognised extension is handed over with **no**
   declared MIME type so the receiver can sniff it, because declaring a guess is
   worse than declaring nothing — the receiver trusts it.
2. **At runtime** — `GoogleCastProvider` watches both the `loadMedia` request
   (`GCKRequestDelegate`) and the receiver's status
   (`GCKRemoteMediaClientListener` → `playerState == .idle && idleReason == .error`)
   and reports a `CastFailure` up through `CastService.castFailure`. This is the
   only way to catch the two things a URL can't reveal:
   - **CORS.** Google's receiver requires `Access-Control-Allow-Origin` on
     adaptive streams, and IPTV providers rarely send it — so an `.m3u8` that
     passes layer 1 may still be refused. Note Xtream live defaults to HLS
     (`XtreamClient`), so this is the common live-TV case; a playlist switched to
     MPEG-TS needs no CORS.
   - **Codecs.** A supported container with contents the receiver can't decode —
     HEVC inside MPEG-TS being the usual IPTV example.

Loading is centralized in `FullScreenPlayerView.loadOntoReceiver()`, invoked on
session connect, on player open with a session already active, and whenever
`displayMedia`'s URL changes mid-cast (Stalker resolve landing, episode/channel
switch). `GoogleCastProvider` ignores re-loads of the URL already playing, so
those edges can all call it unconditionally. When the session ends, the active
stream is rebased to the receiver's last position and the local engine resumes
there.

## Remaining work

- **On-device verification:** the integration is verified to build, link, and
  embed on the iOS simulator, but casting to a physical receiver has not been
  exercised end-to-end (discovery, load, transport, session teardown). The
  failure paths above are likewise unexercised against real hardware — they are
  reasoned from Google's supported-media documentation, not observed.
- **Orphaned sessions:** a session outlives the player by design, but the cast
  button only exists inside the player overlays, so a session left running after
  the player closes can't be reached or stopped from anywhere in the app.
  `CastProvider.endSession()` has no call site yet. Needs either a mini
  controller or an end-on-dismiss decision.
- **Vendored SDK:** `Vendor/GoogleCast` is 23 MB / ~1000 files committed to git
  because Google ships no SPM package. Should move to a remote `binaryTarget`
  (checksummed zip) so it resolves instead of being stored.
- **Receiver-side finish → NextUp:** when the receiver plays a VOD stream to the
  end, the session just goes idle; auto-advance to the next episode (the local
  engines' NextUp flow) isn't triggered from the receiver's `.finished` idle
  reason yet.
- **Subtitles/audio tracks on the receiver:** track selection isn't exposed
  while casting.
