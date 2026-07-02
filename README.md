<div align="center">

<img src=".github/assets/lume-banner.png" alt="Lume" width="640">

### A modern, native IPTV player for Apple platforms

Browse, search, and stream your Xtream Codes or **M3U/M3U8** playlists with a clean SwiftUI interface — Live TV, Movies, and Series, enriched with metadata, EPG, and watch progress that follows you across your devices.

<br>

<a href="https://apps.apple.com/us/app/lume-iptv-player/id6779551584">
  <img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/en-us?releaseDate=1700000000" alt="Download Lume on the App Store" height="48">
</a>

<br><br>

[![App Store](https://img.shields.io/badge/Download-App%20Store-0A84FF?logo=apple&logoColor=white&labelColor=1f1f2e)](https://apps.apple.com/us/app/lume-iptv-player/id6779551584)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20·%20iPadOS%20·%20macOS%20·%20tvOS%20·%20visionOS-1f1f2e?labelColor=1f1f2e)](#supported-platforms)
[![Swift](https://img.shields.io/badge/Swift-5.x-F05138?logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)](https://developer.apple.com/xcode/swiftui/)
[![SwiftData](https://img.shields.io/badge/Persistence-SwiftData-30B0C7)](https://developer.apple.com/documentation/swiftdata)
[![Issues](https://img.shields.io/github/issues/bilipp/Lume?color=F9EE00&labelColor=1f1f2e)](https://github.com/bilipp/Lume/issues)
[![Discord](https://img.shields.io/badge/chat-Discord-5865F2?logo=discord&logoColor=white&labelColor=1f1f2e)](https://discord.gg/DMnQfr69Ug)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue?labelColor=1f1f2e)](LICENSE)

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
- [Anti-piracy](#anti-piracy)
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
> provider you are entitled to use. We do not condone piracy — please read the
> [**Anti-Piracy Policy**](ANTI_PIRACY.md).

---

## Features

#### 📺 Live TV
- Browse channels by category with logos and **EPG** data (now & next)
- Full **program guide** with a scrollable timeline
- **Custom EPG sources**: add external XMLTV feeds, refresh the guide on its own schedule, and sync manually — managed separately from playlist content
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
- **For You** rail — on-device recommendations from your watch history and favorites; thumbs-up / thumbs-down a suggestion to tune what you see next, with your votes syncing across devices via iCloud (can be turned off in Settings)

#### 🔎 Discovery & organization
- Global search across Movies, Series, and Live channels with type filtering
- **Background content indexing** — matches the whole library against TMDB and builds on-device embedding vectors (Apple NaturalLanguage) as the foundation for semantic search
- Configurable sort options per category and content type
- Hide and reorder categories to taste
- Favorites and watched markers across every content type
- **Deep links** — open a title straight from a URL: `lume://movie/{tmdbId}` and `lume://series/{tmdbId}`

#### ⏱️ Watch tracking
- Automatic resume playback and progress tracking
- Auto-mark-as-watched at 90% completion
- **Next Up** overlay with auto-play for series episodes
- **Skip Intro / Recap** overlay during playback, powered by IntroDB skip windows
- Optional **Trakt** scrobbling — plus one-tap import of your existing Trakt watched history — and **TMDB** metadata enrichment
- **Clear watch history** from Settings to reset progress, watched markers, and last-watched dates across all content

#### 👤 Profiles
- Multiple **user profiles**, each with its own watch history, progress, and favorites
- Switch profiles from the top-left of Home (iOS / macOS) or in Settings (tvOS)
- Profiles and their state **sync across your devices** via iCloud
- **Parental controls**: mark profiles as child profiles, restrict categories (hidden from browsing and search), and protect them with a PIN required to leave a child profile or open Content Management

#### ⚙️ Library management
- Manage multiple playlists — **Xtream Codes**, **M3U/M3U8**, and **Stalker portals** (add / edit / delete / switch)
- M3U support: URL-based playlists, local file import, URL-tvg EPG auto-detection
- Stalker portal support: MAC-address authentication (with a generated default MAC), with short-lived stream URLs resolved on demand at playback time
- Server info at a glance: status, active connections, expiry
- Background **content sync** with step-by-step progress, which **prunes stale titles** the provider has dropped so the local catalog stays in step
- Scheduled **auto-sync** (every 6 hours, daily, every 3 days, or weekly)

---

## Supported platforms

Lume is a single SwiftUI codebase that adapts to each platform's idioms — including a
dedicated focus-driven interface and top-shelf branding on tvOS.

| Platform | Minimum OS | Devices |
|---|---|---|
| iOS / iPadOS | 18.0 | iPhone, iPad |
| macOS | 15.0 | Apple Silicon & Intel |
| tvOS | 18.0 | Apple TV 4K |
| visionOS | 2.0 | Apple Vision Pro |

> Liquid Glass and the iOS 26 navigation refinements are used where available and fall back to standard system materials on older OS versions.

---

## Playback engines

Lume ships with three interchangeable engines, ordered into a **priority list** in
**Settings**. Playback starts with your preferred engine and **automatically falls
back** to the next one whenever an engine can't play a stream, so a codec or stream
one engine chokes on is retried with another before any error is shown. The default
order is **KSPlayer → VLCKit → AVPlayer** (degrading to whichever engines are
available on the platform).

| Engine | Backend | Best for | Notes |
|---|---|---|---|
| **VLCKit** | VLCKit 4 (libVLC) | Maximum compatibility | Virtually any format/codec, hardware-accelerated 4K HDR, Picture in Picture, broadest IPTV support |
| **KSPlayer** | FFmpeg (FFmpegKit) | Wide IPTV support | Handles most formats common in IPTV streams; configurable decoder (FFmpeg / VideoToolbox) |
| **AVPlayer** | AVFoundation | HLS & MP4 | Native Apple player with **custom unified overlay** matching the other engines |

Prefer a third-party app? Lume can hand streams off to an **external player** —
**Infuse** or **VLC** — via their deep-link APIs, selectable in **Settings**.
Downloads always play in Lume, and playback falls back to the built-in player when
the selected app is not installed.

Send playback to the TV with **AirPlay** — a route picker sits in the player overlay
on iOS, iPadOS, and macOS. Full-screen video is delivered through Apple's AVPlayer,
so when you pick a receiver while on the KSPlayer or VLCKit engine the current stream
is handed to AVPlayer for the cast and resumes where it left off (formats AVPlayer
can't decode fall back to audio-only). (Chromecast support is on the [roadmap](#roadmap).)

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
│    ├─ StalkerClient       Stalker portal (MAC auth)       │
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
- **Localization** — 9 languages via String Catalogs (English, German, French, Spanish, Italian, Portuguese, Japanese, Korean, Simplified Chinese)

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

The easiest way to use Lume is to [**download it from the App Store**](https://apps.apple.com/us/app/lume-iptv-player/id6779551584) — available on iPhone, iPad, Mac, Apple TV, and Apple Vision Pro. To build from source, follow the steps below.

### Requirements

- **Xcode 26.4** or later
- An **Xtream Codes** account (server URL, username, password), an **M3U/M3U8 playlist URL**, or a **Stalker portal** (portal URL + MAC address)
- *(Optional)* a [TMDB](https://www.themoviedb.org/settings/api) API access token for metadata enrichment
- *(Optional)* a [Trakt](https://trakt.tv/oauth/applications) application for scrobbling
- *(Optional)* an [OMDb](https://www.omdbapi.com/apikey.aspx) API key for IMDb / Rotten Tomatoes / Metacritic ratings
- *(Optional)* an [IntroDB](https://introdb.app) API key for intro / recap skip windows

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

**Code signing.** The project ships with the maintainer's Development Team
(`DEVELOPMENT_TEAM`) and bundle identifier (`com.bilipp.lume`). Simulator builds run as
is. To run on a physical device, open **Signing & Capabilities** for each target and set
your own team (and, if needed, a unique bundle identifier) — or clear the team for a
simulator-only build. Don't commit these personal signing changes back to the repo.

---

## Configuration

Optional integrations (TMDB, OMDb, IntroDB, and Trakt) are configured through a
repo-root `.env` file. The `Scripts/inject-env.sh` build phase reads it and injects the
values into the built app's `Info.plist` — keeping secrets out of source control. `.env`
is gitignored, and if it is missing the dependent features simply degrade gracefully
(e.g. the Trending rail hides).

Copy the template and fill in the keys you have:

```bash
cp .env.example .env
```

```dotenv
# TMDB — metadata, artwork & trailers
TMDB_ACCESS_TOKEN=your_tmdb_v4_read_access_token

# OMDb — IMDb, Rotten Tomatoes & Metacritic ratings
OMDB_API_KEY=your_omdb_api_key

# IntroDB — intro / recap skip windows (read access works unauthenticated)
INTRO_DB_API_KEY=your_introdb_api_key

# Trakt — watch scrobbling (device OAuth flow)
TRAKT_CLIENT_ID=your_trakt_client_id
TRAKT_CLIENT_SECRET=your_trakt_client_secret
```

Every key is optional — Lume builds and runs fine with an empty `.env` or none at all.

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

> 💬 Have a question, want to share feedback, or just hang out? Join the community on
> **[Discord](https://discord.gg/DMnQfr69Ug)**.

Contributions are welcome! The short version:

1. Open an [issue](https://github.com/bilipp/Lume/issues) to discuss a bug or feature.
2. Fork the repo and create a feature branch off `main`.
3. Run `./Scripts/setup.sh` once to install the git hooks and lint/format tooling —
   [Lefthook](https://lefthook.dev), SwiftFormat, and SwiftLint are all vendored as
   Swift Package plugins, so you only need Xcode's Swift toolchain (no Homebrew or Mint).
4. Make sure the test suite passes before opening a pull request.

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full guide — dev setup, coding style,
localization, commit conventions, and the PR checklist.

---

## Anti-piracy

Lume is a **player only** — it ships with no channels, streams, playlists, or media of
any kind, and it pre-configures no providers. Every stream you watch comes solely from
the Xtream Codes credentials or M3U playlist **you** supply.

We do **not** condone or support piracy. Use Lume only with content you are legally
entitled to access — a legitimate IPTV subscription, your own playlists, or
free-to-air and openly licensed streams. Requesting, sharing, or linking to pirated
streams, playlists, or credentials is **not allowed** in this repository, issues, pull
requests, or any community space, and may result in removal and bans.

Please read the full **[Anti-Piracy Policy](ANTI_PIRACY.md)** before opening issues or
joining the community.

---

## License

Lume is free software, licensed under the **GNU Affero General Public License v3.0
(AGPL-3.0)**. See [`LICENSE`](LICENSE) for the full text.

In short — you are free to use, study, modify, and redistribute Lume, but **any
project that incorporates this code must also be released as open source under the
AGPL-3.0**. This requirement extends to software offered over a network: if you run a
modified version of Lume as a network service, you must make your modified source
available to its users.

```
Copyright (C) 2026 Philipp Bischoff

This program is free software: you can redistribute it and/or modify it under the
terms of the GNU Affero General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.
```

<div align="center">
<br>
<sub>Built with SwiftUI for iPhone, iPad, Mac, Apple TV & Vision Pro.</sub>
</div>
