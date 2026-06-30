# Chromecast integration

Lume ships the **wiring** for Chromecast but not the **Google Cast SDK** itself.
The SDK is a heavyweight, iOS-only, closed-source binary with its own
privacy-manifest footprint, so it is left out of the default build. Everything in
the codebase is gated behind `#if canImport(GoogleCast)`, so the app compiles and
runs unchanged until you add the dependency by following the steps below.

This complements the native **AirPlay** support, which needs no third-party SDK
(see the player overlay's AirPlay button). Chromecast targets **iOS / iPadOS
only** — the Cast SDK has no macOS, tvOS, or visionOS build.

## What's already in place

| Piece | File | Role |
|---|---|---|
| Casting seam | `Lume/Services/Player/CastService.swift` | `CastProvider` protocol + `configureGoogleCast()` registration (no-op without the SDK) |
| Provider | `Lume/Services/Player/GoogleCastProvider.swift` | `GCKSessionManager` / `GCKRemoteMediaClient` bridge to `CastProvider`; loads the current `PlayableMedia`, exposes play/pause/seek and a progress callback |
| Cast button | `Lume/Views/Player/ChromecastButton.swift` | `GCKUICastButton` styled to match the overlay; renders nothing until the SDK is linked |
| Launch hook | `Lume/LumeApp.swift` | calls `CastService.shared.configureGoogleCast()` |
| Discovery keys | `Lume/Info.plist` | `NSBonjourServices` + `NSLocalNetworkUsageDescription` |

## Adding the SDK

1. **Add the Swift Package** in Xcode (File ▸ Add Package Dependencies):

   ```
   https://github.com/google/cast-sdk-ios
   ```

   Add the **`GoogleCast`** product to the **Lume** target's iOS destination only.
   (If you prefer the no-Bluetooth variant to avoid the Bluetooth privacy prompt,
   use that product instead — both define the `GoogleCast` module the gates check.)

2. **Build for an iOS destination.** `canImport(GoogleCast)` now resolves true, so
   `GoogleCastProvider`, the `ChromecastButton`, and `configureGoogleCast()` start
   compiling and the cast button appears in the player overlay when a receiver is
   on the network.

3. **Receiver app ID.** The scaffold uses Google's Default Media Receiver
   (`kGCKDefaultMediaReceiverApplicationID`, id `CC1AD845`). If you register a
   styled/custom receiver in the [Google Cast Developer Console](https://cast.google.com/publish),
   swap the id in `CastService.configureGoogleCast()` **and** the
   `_CC1AD845._googlecast._tcp` entry in `Info.plist`.

## Privacy manifest

The Google Cast SDK accesses the local network and (in the full variant)
Bluetooth, and may declare required-reason APIs. Before shipping:

- Confirm the SDK bundles its own `PrivacyInfo.xcprivacy` (recent versions do); if
  not, account for its data use in Lume's `PrivacyInfo.xcprivacy`.
- The `NSLocalNetworkUsageDescription` string in `Info.plist` is English-only —
  localize it alongside the other catalog strings before release.
- Re-run the privacy report (see the `privacy-manifest` skill) after linking.

## Remaining work

- **Transport mirroring:** the overlay's transport controls (play/pause/seek) act
  on the local engine. Route them to `GoogleCastProvider` while a session is
  active, and reflect the receiver's `GCKMediaStatus` back into the overlay.
- **Watch progress:** `GoogleCastProvider.onProgress` reports the receiver's
  position; wire it to `WatchProgressWriter` so casting updates resume points and
  the 90%-watched / NextUp flow, the same way local playback does.
- **Engine pause:** when a cast session starts, pause the on-device engine so the
  stream isn't decoded twice.
- **On-device verification:** none of the gated code has been compiled or run in
  CI — exercise it against a real Cast device before release.
