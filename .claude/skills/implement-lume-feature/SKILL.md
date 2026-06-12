---
name: implement-lume-feature
description: Implement a feature in the Lume iOS/tvOS/macOS/visionOS app. Accepts either free-form feature instructions or a GitHub issue URL/number. Handles implementation, localization, tests, README updates, and opens a PR. Use when asked to implement, build, or add a feature to Lume.
---

# /implement-lume-feature — Lume Feature Implementer

Implement a feature for the Lume IPTV app from a description or GitHub issue, then open a PR — all in one shot.

## Usage

```
/implement-lume-feature <github-issue-url-or-number>
/implement-lume-feature <free-form description of the feature>
```

**Examples:**
- `/implement-lume-feature https://github.com/bilipp/Lume/issues/42`
- `/implement-lume-feature #42`
- `/implement-lume-feature Add a sleep timer that stops playback after a configurable duration`

---

## Execution Steps

Follow these steps exactly and in order.

### 1. Parse the Input

Determine the input type:

- **GitHub issue** — input matches any of: full `https://github.com/bilipp/Lume/issues/<n>` URL, bare `#<n>`, or a plain integer. Extract the issue number.
- **Free-form instructions** — anything else.

If the input is ambiguous (e.g. a number without `#`), treat it as a GitHub issue number.

### 2. Fetch the GitHub Issue (if applicable)

If the input is a GitHub issue, fetch it with the GitHub MCP tool `mcp__plugin_github_github__issue_read`:

```json
{ "owner": "bilipp", "repo": "Lume", "issue_number": <n> }
```

Collect:
- **Title** — one-line summary
- **Body** — full description, acceptance criteria, design notes
- **Labels** — hints for affected area (`live-tv`, `movies`, `series`, `player`, `settings`, `home`, `search`, `tvos`, `ui`, etc.)
- **Linked issues / PRs** — related context

If the MCP call fails, fall back to `mcp__plugin_github_github__fetch` with the issue URL.

If the input is free-form, treat the text as the feature description and skip this step.

### 3. Check Axiom Skills

**Before writing any code**, identify which Axiom skills apply to this feature and invoke ALL relevant ones:

| If the feature involves… | Invoke |
|---|---|
| Any SwiftUI view, layout, navigation, animation | `axiom:axiom-swiftui` |
| SwiftData models, migrations, queries | `axiom:axiom-data` |
| async/await, actors, Task, @MainActor, Sendable | `axiom:axiom-concurrency` |
| AVPlayer, VLCKit, KSPlayer, video/audio | `axiom:axiom-media` |
| URLSession, networking, API clients | `axiom:axiom-networking` |
| Memory, performance, Instruments | `axiom:axiom-performance` |
| Keychain, privacy, entitlements | `axiom:axiom-security` |
| StoreKit, in-app purchases | `axiom:axiom-shipping` |
| tvOS-specific UI, focus engine | `axiom:axiom-swiftui` + `axiom:axiom-apple-docs` |
| Apple frameworks, API questions | `axiom:axiom-apple-docs` |
| Location, maps | `axiom:axiom-location` |
| Testing patterns | `axiom:axiom-testing` |

Follow each Axiom skill's guidance before writing code for that domain.

### 4. Understand the Feature

Read the issue / instructions thoroughly. Identify:

- **What to build** and the user need it addresses
- **Which platform(s)** are affected (iOS, tvOS, macOS, visionOS — or all)
- **Which area** is touched: `Home`, `LiveTV`, `Movies`, `Series`, `Player`, `Settings`, `Search`, `Components`, `Models`, `Services`
- **Acceptance criteria** — the definition of done
- **Constraints** — performance, backwards compatibility, platform minimums (iOS/tvOS/macOS/visionOS 26.4)

### 5. Locate the Code

Search the repository for the files you need to read:

- Use area names, type names, and identifiers from the description as search terms
- Read every relevant file fully before making changes — do not guess
- Key paths to orient yourself:
  - `Lume/Models/` — SwiftData models
  - `Lume/Services/` — networking, sync, player, images
  - `Lume/Views/Home/` · `Views/LiveTV/` · `Views/Movies/` · `Views/Series/` · `Views/Player/` · `Views/Settings/` · `Views/Components/`
  - `Lume/Views/TV/` — tvOS-specific detail screens
  - `LumeTests/` — unit/integration tests (Swift Testing)
  - `LumeUITests/` — UI automation (XCTest)

### 6. Create the Feature Branch

Start from the latest `main`:

```bash
git -C <repo-root> checkout main
git -C <repo-root> pull
git -C <repo-root> checkout -b feature/<slug>
```

Derive `<slug>` from the issue title or feature description: lowercase, words joined with hyphens, max 5 words (e.g. `sleep-timer`, `channel-favorites-reorder`, `epg-full-screen`). If the input was a GitHub issue, prefix with the issue number: `42-sleep-timer`.

If the branch already exists, ask the user whether to reset it or use a different suffix.

> **Worktree note:** If you are already working inside a git worktree for this task (i.e. the current directory is under `~/Projects/worktrees/Lume/`), the branch is already checked out — skip the branch creation commands and proceed directly.

### 7. Implement the Feature

Apply a focused implementation that satisfies the acceptance criteria:

**Code conventions:**
- All UI in SwiftUI — no UIKit unless bridging is unavoidable
- Platform-adaptive code via `#if os(tvOS)` / `#if os(iOS)` / `#if os(macOS)` / `#if os(visionOS)` only where behaviour truly differs
- SwiftData for all persistence — no UserDefaults for structured data (UserDefaults is acceptable for small scalar flags)
- `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` is set globally — value types / DTOs used by `nonisolated` callers must be marked `nonisolated`
- No `@StateObject` / `ObservableObject` — use `@Observable` + `@State` / `@Environment`
- Do not refactor unrelated code
- Do not add functionality beyond what the feature requires
- Do not add comments that explain what changed (the commit message does that)
- Write no comments unless the reason is non-obvious (hidden constraint, subtle invariant, workaround for a specific bug)

**Lume-specific patterns to follow:**
- New SwiftData models: add to the schema array in `LumeApp.swift`
- New user-facing strings: add keys to `Lume/Localizable.xcstrings` (step 9 syncs them)
- Platform-specific focus behaviour on tvOS: never drive layout from `@FocusState`; use `.focusSection()` and `ScrollTargetBehavior` instead (see memory: tvOS hero collapse instability)
- `@Binding` rooted in `@Observable`: thread the object, read only in the leaf — not a binding — to avoid full-view re-renders (see memory: @Binding-to-@Observable re-render trap)
- Avoid `Color.accentColor` for fills/tints on tvOS — it resolves to white (see memory: Empty AccentColor → white on tvOS)

### 8. Run the Linter

Before committing, fix all lint errors:

```bash
# Run from the repo root
swiftformat . --trailing-commas neverassets
swiftlint --fix && swiftlint
```

If SwiftLint reports errors that cannot be auto-fixed, resolve them manually. Do not push code that fails lint.

> Pre-commit hooks enforce these as errors — pushing without passing them will fail.

### 9. Add Localization Strings

For every new user-facing string introduced:

1. Add a key + English value to `Lume/Localizable.xcstrings`
2. Run xcstringstool to sync placeholders for German (and any other locales):

```bash
xcstringstool sync --language de Lume/Localizable.xcstrings
```

3. Provide a German translation for each new key, or leave the German value as the English fallback if you are not confident in the translation — mark it with a comment `/* TODO: translate */` so it is visible in Xcode.

> Do NOT delete manually-added runtime keys — `xcstringstool sync` removes keys it cannot find in source; if a key was added manually, mark it with `extractionState: "manual"` in the xcstrings file.

### 10. Assess and Write Tests

Evaluate whether automated tests should be added.

**Write tests if all of the following are true:**
- The feature introduces logic that can be exercised in isolation (function, method, service, model)
- A test framework/suite exists for the affected module (it does — `LumeTests` uses Swift Testing)
- Tests would provide meaningful coverage of the acceptance criteria

**Skip tests if any of the following apply:**
- The feature is purely visual with no testable logic
- The feature is a configuration or asset change
- Writing meaningful tests would require disproportionate effort

**If writing tests**, follow the Swift Testing patterns used in `LumeTests/`:

```swift
import Foundation
@testable import Lume
import Testing

struct MyFeatureTests {
    @Test func `describes the behaviour`() throws {
        // arrange
        // act
        // #expect(result == expected)
    }
}
```

- Add tests to the existing test file for the affected module, or create one at `LumeTests/<Area>/MyFeatureTests.swift`
- Tests run on the iOS Simulator (`iPhone 17 Pro`) — not tvOS
- Use `@Suite` to group related tests
- Use `#require` for unwrapping optionals that must succeed
- Use the shared `makeModelContainer()` helper in `LumeTests/Helpers/` for in-memory SwiftData containers

**If skipping tests:**
- Note the reason in the PR body (one line).

### 11. Update the README (if needed)

Update `README.md` only if the feature is a **major, user-visible addition** — something a new user would expect to read about before installing the app.

Criteria for a README update:
- New capability listed in the Features section
- New third-party integration (new service, new API)
- New playback engine or supported platform
- New configuration key in `.env`

If a README update is needed:
- Add a bullet under the appropriate section in **Features**
- Update the **Configuration** section if a new `.env` key was added
- Keep bullets concise — match the style of existing bullets

For smaller features (UI improvements, new sort options, internal refactors), skip the README update.

### 12. Determine the Commit Scope

Lume uses **Conventional Commits**. The `scope` in `feat(scope): …` is a short lowercase noun naming the affected area:

| Area | Scope |
|---|---|
| Home dashboard / hero | `home` |
| Live TV / channels / EPG | `live-tv` |
| Movies | `movies` |
| Series / episodes | `series` |
| Playback (any engine) | `player` |
| Settings screens | `settings` |
| Search | `search` |
| SwiftData models | `models` |
| Networking / API clients | `networking` |
| Content sync | `sync` |
| Localization | `i18n` |
| UI components (shared) | `ui` |
| tvOS-specific | `tvos` |
| Downloads | `downloads` |
| Trakt integration | `trakt` |

Choose the scope that best matches the primary change. If the change spans multiple areas, use the most significant one.

### 13. Commit the Changes

Stage only the files changed for this feature and commit:

```bash
git add <changed files>
git commit -m "feat(<scope>): <short description of what was implemented>"
```

If localization or test files were also changed, include them in the same commit.

### 14. Push the Branch

```bash
git push -u origin feature/<slug>
```

### 15. Open a Pull Request

Create the PR with the `gh` CLI. Use this exact title format:

```
feat(<scope>): <short description of what was implemented>
```

**Title examples:**
- `feat(player): add sleep timer with configurable duration`
- `feat(live-tv): show channel logo overlay during zapping`
- `feat(settings): add option to hide watched movies from browse grid`

PR body template:

```markdown
## Summary
<one paragraph: what was built and what user need it addresses>

## Implementation
<one paragraph: what changed and the key decisions made>

## Testing
- [ ] Acceptance criteria met
- [ ] Tests pass (`xcodebuild test -scheme Lume -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`)
- [ ] SwiftLint clean
- [ ] Tests added — or skipped: <reason>

## Platforms
- [ ] iOS / iPadOS
- [ ] tvOS
- [ ] macOS
- [ ] visionOS
<!-- Check each platform the change was manually verified on -->

## Related
<!-- Link the GitHub issue if applicable, e.g.: Closes #42 -->
```

Run:

```bash
gh pr create \
  --repo bilipp/Lume \
  --title "feat(<scope>): <description>" \
  --body "$(cat <<'EOF'
## Summary
<text>

## Implementation
<text>

## Testing
- [ ] Acceptance criteria met
- [ ] Tests pass
- [ ] SwiftLint clean
- [ ] Tests added — or skipped: <reason>

## Platforms
- [ ] iOS / iPadOS
- [ ] tvOS
- [ ] macOS
- [ ] visionOS

## Related
Closes #<n>
EOF
)"
```

### 16. Report Back

Reply with:
- The PR URL
- A one-sentence summary of what was implemented and where
- The branch name, so the user can check it out for manual verification

---

## Error Handling

| Situation | Action |
|---|---|
| GitHub issue not found | Ask the user to verify the issue number or check repo access |
| Issue is a bug, not a feature | Warn the user — suggest `/fix-bug` instead; ask for confirmation before continuing |
| Cannot locate relevant code | Ask the user which file or module to start from |
| SwiftLint / SwiftFormat errors remain after auto-fix | List the specific errors and ask the user for guidance |
| Tests fail after implementation | Do not push — report the failure and ask for guidance |
| `gh` CLI not authenticated | Ask the user to run `gh auth login` |
| Branch already exists | Ask the user whether to reset it or use a different suffix |
| xcstringstool not found | Skip the sync step; note in the PR that German strings need manual review |
| README section is unclear | Match the existing formatting and ask the user to review the diff before committing |
