<div align="center">

<img src=".github/assets/lume-banner.png" alt="Lume" width="640">

### A modern, native IPTV player for Apple platforms

Browse, search, and stream your Xtream Codes or **M3U/M3U8** playlists with a clean SwiftUI interface — Live TV, Movies, and Series, enriched with metadata, EPG, and watch progress that follows you across your devices.

<br>

[![Platforms](https://img.shields.io/badge/platforms-iOS%20·%20iPadOS%20·%20macOS%20·%20tvOS%20·%20visionOS-1f1f2e?labelColor=1f1f2e)](#supported-platforms)
[![Swift](https://img.shields.io/badge/Swift-5.x-F05138?logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)](https://developer.apple.com/xcode/swiftui/)
[![SwiftData](https://img.shields.io/badge/Persistence-SwiftData-30B0C7)](https://developer.apple.com/documentation/swiftdata)
[![Issues](https://img.shields.io/github/issues/bilipp/Lume?color=F9EE00&labelColor=1f1f2e)](https://github.com/bilipp/Lume/issues)

</div>

---

## Table of contents

- [Overview](#overview)
- [Features](#features)
- [Supported platforms](#supported-platforms)
- [Playback engines](#playback-engines)
- [Architecture](#architecture)
- [Project structure](#project-structure)
- [Getting started](#getting-started)
- [Configuration](#configuration)
- [Testing](#testing)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

**Lume** is a native IPTV client for the Apple ecosystem. It connects to your own
**Xtream Codes** provider or imports **M3U/M3U8** playlists, indexes the full catalog
locally with **SwiftData** for instant, offline-capable browsing, and plays everything
through a choice of three playback engines — from VLC's universal codec support to
Apple's native AVPlayer.

It is built entirely in **SwiftUI** with a single, platform-adaptive codebase that
runs on iPhone, iPad, Mac, Apple TV, and Apple Vision Pro. Content is enriched with
artwork, cast, trailers, and ratings from **TMDB** and **OMDb** (IMDb, Rotten Tomatoes,
Metacritic), and your viewing activity can be scrobbled to **Trakt**.

> **Note** — Lume is a player only. It ships with **no channels, streams, or content**
> of its own. You bring your own Xtream Codes credentials or M3U playlist from a
> provider you are entitled to use.

---

## Features

#### 📺 Live TV
- Browse channels by category with logos and **EPG** data (now & next)
- Full **program guide** with a scrollable timeline
- Catchup / time-shift support
- Channel zapping with recently-watched history
- **In-player channel browser** on tvOS (left-press overlay with category/channel grid)
- Favorite channels and per-channel management

#### 🎬 Movies & Series
- Category-based browsing with poster grids and horizontal rails
- Rich detail views: plot, rating, cast, director, genre, runtime, release date
- **External ratings** from IMDb, Rotten Tomatoes, and Metacritic (via OMDb)
- Season / episode navigation with **per-episode progress**
- TMDB-enriched artwork, logos, and trailers
- Quality / source picker when multiple streams are available

#### 🏠 Home
- Personalized dashboard with a hero carousel
- **Immersive full-screen tvOS home** with TMDB backdrop, crossfading hero, and fold-based scroll snapping
- Continue Watching, Favorites, Recently Watched, and Trending rails

#### 🔎 Discovery & organization
- Global search across Movies, Series, and Live channels with type filtering
- Configurable sort options per category and content type
- Hide and reorder categories to taste
- Favorites and watched markers across every content type

#### ⏱️ Watch tracking
- Automatic resume playback and progress tracking
- Auto-mark-as-watched at 90% completion
- **Next Up** overlay with auto-play for series episodes
- Optional **Trakt** scrobbling and **TMDB** metadata enrichment

#### ⚙️ Library management
- Manage multiple playlists — **Xtream Codes** and **M3U/M3U8** (add / edit / delete / switch)
- M3U support: URL-based playlists, local file import, URL-tvg EPG auto-detection
- Server info at a glance: status, active connections, expiry
- Background **content sync** with step-by-step progress
- Scheduled **auto-sync** (every 6 hours, daily, every 3 days, or weekly)

---

## Supported platforms

Lume is a single SwiftUI codebase that adapts to each platform's idioms — including a
dedicated focus-driven interface and top-shelf branding on tvOS.

| Platform | Minimum OS | Devices |
|---|---|---|
| iOS / iPadOS | 26.4 | iPhone, iPad |
| macOS | 26.4 | Apple Silicon & Intel |
| tvOS | 26.4 | Apple TV 4K |
| visionOS | 26.4 | Apple Vision Pro |

---

## Playback engines

Lume ships with three interchangeable engines, selectable in **Settings**. It defaults
to the broadest-compatibility engine available on the platform (VLCKit → KSPlayer →
AVPlayer).

| Engine | Backend | Best for | Notes |
|---|---|---|---|
| **VLCKit** | VLCKit 4 (libVLC) | Maximum compatibility | Virtually any format/codec, hardware-accelerated 4K HDR, Picture in Picture, broadest IPTV support |
| **KSPlayer** | FFmpeg (FFmpegKit) | Wide IPTV support | Handles most formats common in IPTV streams; configurable decoder (FFmpeg / VideoToolbox) |
| **AVPlayer** | AVFoundation | HLS & MP4 | Native Apple player with **custom unified overlay** matching the other engines |

Prefer a third-party app? Lume can hand streams off to an **external player** —
**Infuse** or **VLC** — via their deep-link APIs, selectable in **Settings**.
Downloads always play in Lume, and playback falls back to the built-in player when
the selected app is not installed.

---

## Architecture

Lume follows a clean, layered SwiftUI architecture:

```
┌─────────────────────────────────────────────────────────┐
│  Views (SwiftUI)  — platform-adaptive screens & players  │
├─────────────────────────────────────────────────────────┤
│  Services         — networking, sync, playback, images   │
│    ├─ XtreamClient        Xtream Codes API + DTOs         │
│    ├─ M3UClient/Parser    M3U/M3U8 playlist import       │
│    ├─ TMDBClient          metadata / artwork enrichment   │
│    ├─ OMDBClient          IMDb / RT / Metacritic ratings  │
│    ├─ TraktService        OAuth device flow + scrobbling  │
│    ├─ ContentSyncManager  background catalog indexing     │
│    └─ ImagePipeline        cached async image loading     │
├─────────────────────────────────────────────────────────┤
│  Models (SwiftData) — Playlist · Category · LiveStream    │
│                       Movie · Series · Episode            │
│                       CastMember · EPGListing · ExternalRating │
└─────────────────────────────────────────────────────────┘
```

**Tech stack**

- **UI** — SwiftUI, adaptive across iOS / macOS / tvOS / visionOS
- **Persistence** — SwiftData (8 model types, local catalog index)
- **Playback** — VLCKit · KSPlayer (FFmpegKit) · AVPlayer
- **Networking** — `URLSession` with typed endpoints, retry/backoff, and error classification
- **Integrations** — TMDB (metadata), OMDb (ratings), Trakt (device OAuth + scrobbling)
- **Localization** — English & German via String Catalogs

**Dependencies** (Swift Package Manager)

| Package | Purpose |
|---|---|
| [KSPlayer](https://github.com/kingslay/KSPlayer) | FFmpeg-based playback engine |
| [FFmpegKit](https://github.com/kingslay/FFmpegKit.git) | Media decoding backend for KSPlayer |
| [vlckit-spm](https://github.com/virtualox/vlckit-spm) | VLCKit 4 playback engine |

---

## Project structure

```
Lume/
├── LumeApp.swift            App entry point & SwiftData container
├── ContentView.swift        Root view / login gate
├── Models/                  SwiftData models & sort options
├── Services/
│   ├── Network/             Xtream, M3U, TMDB, OMDb, Trakt clients
│   ├── Sync/                Content sync manager & progress
│   ├── Player/              Playable media, settings, history, NextUp
│   └── Images/              Image cache & pipeline
├── Views/
│   ├── Home/                Dashboard, hero carousel, rails, tvOS fold
│   ├── LiveTV/              Channels & EPG guide
│   ├── Movies/ · Series/    Browse & detail views
│   ├── Player/              AVPlayer / KSPlayer / VLC engines, overlays, channel browser
│   ├── TV/                  tvOS-specific detail screens
│   ├── Settings/            Playlists, sync, Trakt, player engine options, content mgmt
│   └── Components/          Reusable cards, toolbars, grids, ratings chips
└── Assets.xcassets/         App icon & tvOS brand assets

LumeTests/                   Unit & integration tests (Swift Testing)
LumeUITests/                 UI automation tests (XCTest)
Scripts/                     Build helpers (env injection, frameworks)
```

---

## Getting started

### Requirements

- **Xcode 26.4** or later
- An **Xtream Codes** account (server URL, username, password) or an **M3U/M3U8 playlist URL**
- *(Optional)* a [TMDB](https://www.themoviedb.org/settings/api) API access token for metadata enrichment
- *(Optional)* a [Trakt](https://trakt.tv/oauth/applications) application for scrobbling
- *(Optional)* an [OMDb](https://www.omdbapi.com/apikey.aspx) API key for IMDb / Rotten Tomatoes / Metacritic ratings

### Build & run

```bash
git clone https://github.com/bilipp/Lume.git
cd Lume
open Lume.xcodeproj
```

Select the **Lume** scheme and a target destination (iPhone, Mac, Apple TV, or Vision
Pro), then build and run (`⌘R`). On first launch, sign in with your Xtream credentials
or import an M3U playlist, and Lume will sync your catalog.

> Dependencies are resolved automatically by Swift Package Manager on first build.

---

## Configuration

Optional integrations (TMDB and Trakt) are configured through a repo-root `.env` file.
The `Scripts/inject-env.sh` build phase reads it and injects the values into the built
app's `Info.plist` — keeping secrets out of source control. `.env` is gitignored, and
if it is missing the dependent features simply degrade gracefully (e.g. the Trending
rail hides).

Create a `.env` file in the project root:

```dotenv
# TMDB — metadata, artwork & trailers
TMDB_ACCESS_TOKEN=your_tmdb_v4_read_access_token

# OMDb — IMDb, Rotten Tomatoes & Metacritic ratings
OMDB_API_KEY=your_omdb_api_key

# Trakt — watch scrobbling (device OAuth flow)
TRAKT_CLIENT_ID=your_trakt_client_id
TRAKT_CLIENT_SECRET=your_trakt_client_secret
```

Trakt uses the **device OAuth flow** (no embedded web view), which works on tvOS as
well as iOS/macOS. Tokens are stored securely in the Keychain.

---

## Testing

Lume has an extensive test suite split across unit/integration tests (**Swift Testing**)
and UI automation (**XCTest**).

| Target | Framework | Coverage |
|---|---|---|
| `LumeTests` | Swift Testing | DTO decoding, URL building, API client & retry, models, sort options, sync progress & content sync, playable media, player settings, Trakt token store, content organizing, **M3U parser/classifier/sync**, **OMDb client**, **Next Episode resolver**, **Gzip file streaming** |
| `LumeUITests` | XCTest | App launch & performance, login flow, tab navigation, playlist detail, settings, **M3U playlist import flow** |

Run the full suite:

```bash
xcodebuild test \
  -project Lume.xcodeproj \
  -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run a single target:

```bash
# Unit / integration tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeTests

# UI tests only
xcodebuild test -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeUITests
```

Decoding tests run against real, anonymized API payloads in `ExampleData/`. Shared
helpers in `LumeTests/Helpers/TestHelpers.swift` provide an in-memory `ModelContainer`
and JSON loaders so tests need no bundle-resource setup.

---

## Roadmap

Planned features and enhancements are tracked as
[**GitHub Issues**](https://github.com/bilipp/Lume/issues).

---

## Contributing

Contributions are welcome! If you'd like to help:

1. Open an [issue](https://github.com/bilipp/Lume/issues) to discuss a bug or feature.
2. Fork the repo and create a feature branch.
3. Keep the code style consistent (SwiftFormat & SwiftLint configs are included).
4. Make sure the test suite passes before opening a pull request.

---

## License

This project does not yet include an open-source license. Until one is added, all
rights are reserved by the author. If you'd like to use or contribute to Lume, please
open an issue to discuss.

<div align="center">
<br>
<sub>Built with SwiftUI for iPhone, iPad, Mac, Apple TV & Vision Pro.</sub>
</div>
