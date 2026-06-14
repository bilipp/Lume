# Contributing to Lume

Thanks for your interest in improving Lume! This guide covers everything you need to
go from a fresh clone to an open pull request. For an overview of the project,
architecture, and tech stack, see the [README](README.md).

> **A note on content** — Lume is a *player only*. It ships with no channels, streams,
> or content of its own, and contributions must not add any. Bug reports and feature
> requests should never include real provider credentials, playlist URLs, or stream
> links.

---

## Table of contents

- [Code of conduct](#code-of-conduct)
- [Ways to contribute](#ways-to-contribute)
- [Development environment](#development-environment)
- [Project layout](#project-layout)
- [Coding style](#coding-style)
- [Localization](#localization)
- [Testing](#testing)
- [Commit messages](#commit-messages)
- [Pull requests](#pull-requests)
- [Reporting bugs](#reporting-bugs)
- [License](#license)

---

## Code of conduct

Be respectful, constructive, and welcoming. We want Lume to be a friendly place for
contributors of every experience level. Harassment or hostile behavior of any kind is
not tolerated.

---

## Ways to contribute

- **Report a bug** — open a [GitHub issue](https://github.com/bilipp/Lume/issues) with
  clear reproduction steps (see [Reporting bugs](#reporting-bugs)).
- **Propose a feature** — open an issue to discuss it *before* you start coding. This
  avoids duplicated effort and gives the idea a chance to be shaped early.
- **Fix something** — small, focused fixes are very welcome. For anything larger than a
  bug fix, please open an issue first so we can agree on the approach.
- **Improve docs** — corrections and clarifications to the README or this guide are
  always appreciated.

Planned work is tracked in [GitHub Issues](https://github.com/bilipp/Lume/issues).

---

## Development environment

### Requirements

- **Xcode 26.4** or later (Swift 6.3 toolchain)
- macOS capable of running that Xcode
- *(Optional)* TMDB / OMDb / Trakt API keys for the metadata, ratings, and scrobbling
  features — see [Configuration](README.md#configuration). Features degrade gracefully
  when keys are absent, so you don't need them to build and run.

### First-time setup

```bash
git clone https://github.com/bilipp/Lume.git
cd Lume
./Scripts/setup.sh        # installs git hooks + lint/format tooling
open Lume.xcodeproj
```

`./Scripts/setup.sh` is the one command you must run after cloning. It installs the
[Lefthook](https://lefthook.dev) git hooks and warms the lint/format tools. Everything
— Lefthook, SwiftFormat, and SwiftLint — is vendored as a Swift Package Manager plugin
in `Package.swift`, so **only Xcode's Swift toolchain is required** (no Homebrew, no
Mint). The first run builds SwiftFormat from source once (~10 s) and caches it.

Dependencies (KSPlayer, FFmpegKit, VLCKit) are resolved automatically by SPM on first
build.

---

## Project layout

A quick map (full version in the [README](README.md#project-structure)):

```
Lume/
├── Models/        SwiftData models & sort options
├── Services/      Network clients, sync, playback, image pipeline
├── Views/         Platform-adaptive SwiftUI screens & players
└── ...
LumeTests/         Unit & integration tests (Swift Testing)
LumeUITests/       UI automation tests (XCTest)
Scripts/           Build & dev-tooling helpers
```

Lume is a **single, platform-adaptive SwiftUI codebase** targeting iOS, iPadOS, macOS,
tvOS, and visionOS. When you touch shared code, keep all five platforms in mind — and
prefer platform-conditional code (`#if os(tvOS)`) over forking views where practical.

---

## Coding style

Style is enforced automatically, so you rarely have to think about it:

- **SwiftFormat** auto-formats every staged `.swift` file on commit (config:
  [`.swiftformat`](.swiftformat)).
- **SwiftLint** runs `--strict` on commit, so **warnings block the commit** (config:
  [`.swiftlint.yml`](.swiftlint.yml)). Notable limits: 200-char lines (warn), 600-line
  files (warn), 400-line type bodies (warn).
- The git hooks re-stage any auto-fixes, so a clean `git commit` means your change
  already conforms.

Beyond the linters, please match the conventions of the surrounding code: comment
density, naming, and idioms. Read like the neighbors.

If a hook ever gets in your way locally, you can add personal overrides in
`lefthook-local.yml` (gitignored) — but don't bypass the hooks for code you intend to
push.

---

## Localization

Lume ships in **English and German** via String Catalogs (`.xcstrings`). If your change
adds or alters user-facing text:

1. Add the string through the String Catalog (or via `xcstringstool sync`) — never
   hard-code user-facing strings.
2. Provide both the English (`en`) and German (`de`) translations.
3. A pre-commit hook normalizes `.xcstrings` files to Xcode's canonical JSON format so
   diffs stay byte-stable — let it run rather than hand-editing the JSON.

---

## Testing

Lume has an extensive suite split across **Swift Testing** (`LumeTests`) and **XCTest**
UI automation (`LumeUITests`). **Run the suite before opening a PR**, and add or update
tests for the behavior you change.

```bash
# Full suite
xcodebuild test \
  -project Lume.xcodeproj \
  -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Unit / integration only
xcodebuild test -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LumeTests
```

Decoding tests run against anonymized API payloads in `ExampleData/`. Shared helpers in
`LumeTests/Helpers/TestHelpers.swift` provide an in-memory `ModelContainer` and JSON
loaders — reuse them rather than rolling your own setup. See
[Testing](README.md#testing) for full coverage details.

---

## Commit messages

Lume follows the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<optional scope>): <short, imperative summary>
```

Common types: `feat`, `fix`, `perf`, `refactor`, `build`, `docs`, `test`, `chore`.
Scopes used in this repo include `sync`, `ui`, `player`, and similar. Examples from the
history:

```
fix(sync): make aborting a playlist sync actually stop it
perf(ui): cap Movies/Series preview rows at 4, list rest as tiles
build: add pre-commit hooks via Lefthook + normalize String Catalog
```

Keep the summary in the imperative mood and under ~72 characters; add a body if the
*why* isn't obvious from the summary.

---

## Pull requests

1. **Open an issue first** for bugs and features so the change can be discussed.
2. **Fork** the repo and create a feature branch off `main`. Branch names follow the
   commit-type convention, e.g. `feat/recently-added-rows` or `fix/sync-abort`.
3. Make focused commits following the [commit message](#commit-messages) format.
4. Ensure the **pre-commit hooks pass** (they run automatically) and the **test suite is
   green** on at least the iOS simulator.
5. If you changed user-facing text, confirm **both `en` and `de`** are localized.
6. Open the PR against `main` with a clear description of *what* changed and *why*, and
   link the related issue (`Closes #123`). Include screenshots or recordings for UI
   changes, ideally noting which platform(s) you verified.
7. Keep PRs reasonably small and single-purpose — it makes review faster and merges
   safer.

A maintainer will review your PR and may request changes. Once approved, it'll be merged.

---

## License

By contributing to Lume, you agree that your contributions will be licensed under the
**GNU Affero General Public License v3.0 (AGPL-3.0)**, the same license that covers the
project. See [`LICENSE`](LICENSE) for the full text.
