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
| Casting seam | `Lume/Services/Player/CastService.swift` | `CastProvider` protocol + `configureGoogleCast()` registration |
| Provider | `Lume/Services/Player/GoogleCastProvider.swift` | `GCKSessionManager` / `GCKRemoteMediaClient` bridge; loads the current `PlayableMedia`, exposes play/pause/seek + a progress callback |
| Cast button | `Lume/Views/Player/ChromecastButton.swift` | `GCKUICastButton` styled to match the overlay |
| Launch hook | `Lume/LumeApp.swift` | calls `CastService.shared.configureGoogleCast()` |
| Discovery keys | `Lume/Info.plist` | `NSBonjourServices`, `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription` |

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

## Remaining work (not yet wired)

The SDK links and the cast button discovers/starts sessions, but the transport is
not yet fully bridged — verify and finish on a real Cast device:

- **Transport mirroring:** the overlay's play/pause/seek act on the local engine.
  Route them to the active `GoogleCastProvider` session and reflect the receiver's
  `GCKMediaStatus` back into the overlay.
- **Watch progress:** wire `GoogleCastProvider.onProgress` to `WatchProgressWriter`
  so casting updates resume points and the 90%-watched / NextUp flow.
- **Engine pause:** pause the on-device engine when a cast session starts so the
  stream isn't decoded in two places.
- **Localize** the `NSLocalNetworkUsageDescription` / `NSBluetoothAlwaysUsageDescription`
  strings (currently English-only).
- **On-device verification:** the integration is verified to build, link, and
  embed on the iOS simulator, but casting to a physical receiver has not been
  exercised.
