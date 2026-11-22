<!--
Thanks for contributing to Lume! Please read CONTRIBUTING.md if you haven't yet.
Title: Conventional Commits, e.g. `feat(player): add a sleep timer` or `fix(sync): keep the cursor after a failed pull`.
Keep the PR to one purpose. Delete the sections and comments that don't apply.
-->

## Summary

<!-- One paragraph: what changes for the user, and why. For a bug: what went wrong and where it was seen. -->

## Implementation

<!-- What changed in the code and how it works. Name the types and files a reviewer should start with. -->

## Decisions

<!-- Product and technical choices a reviewer might question, one bullet each.
     Include what you deliberately left out or deferred. Delete if there are none. -->

-

## Testing

<!-- Check only what you actually did. For anything unchecked or not applicable, say why on the same line. -->

- [ ] Builds clean:
- [ ] Tests pass (`LumeTests`, plus `LumeUITests` if you touched a flow):
- [ ] Pre-commit hooks pass (SwiftFormat, SwiftLint `--strict`, String Catalog normalization)
- [ ] Tests added — or skipped:
- [ ] UI verified on a simulator or device — or n/a:
- [ ] User-facing text localized in `en` and `de` — or n/a:
- [ ] What's New entry added (`WhatsNewCatalog` + `WhatsNew.xcstrings`) — or n/a:

<!-- Not verified: list what you couldn't check (states, platforms, real devices). -->

## Screenshots

<!--
UI changes only. Delete this section for logic-only PRs.

- One row per screen or state, one column per platform you verified.
- A changed screen gets Before | After columns instead; a new one just the result.
- Width 300 for iPhone, 480 for iPad, tvOS, macOS and visionOS.
- Show a populated state, not an empty one, unless the empty state is the change.
- Drag the images into this editor and GitHub hosts them. Don't commit screenshots to the repo.

This repo is public, so every image must be safe to publish:
- Content from the IPTVExampleServer catalog only. No real provider, playlist, channel name, logo or EPG.
- No server URLs, usernames, MAC addresses, tokens, account names, email addresses or device names.
- Check each image before you upload it. If one breaks a rule, retake it or leave it out; don't blur it.
-->

| | iOS | tvOS | macOS |
|---|---|---|---|
| <!-- screen / state --> | <img src="" width="300"> | <img src="" width="480"> | <img src="" width="480"> |

## Platforms

<!-- Check only the platforms you ran the change on. "Built, not run" stays unchecked with a note.
     Each checked platform should have a screenshot above when the change is visible. -->

- [ ] iOS / iPadOS
- [ ] tvOS
- [ ] macOS
- [ ] visionOS

## Related

<!-- `Closes #123`, a stacked or follow-up PR, or the report this came from. Features and non-trivial changes need an issue first. -->

<!-- Before you submit: no credentials, stream URLs, provider names or account IDs anywhere in the diff, commits, logs or fixtures. -->
