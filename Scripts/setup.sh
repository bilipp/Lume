#!/bin/bash
# One-time developer setup for Lume. Installs the git hooks from lefthook.yml plus the
# lint/format tools — all vendored as SPM plugins in Package.swift, so only the Swift
# toolchain that ships with Xcode is required (no Homebrew/Mint). Safe to re-run.
set -e

cd "$(git rev-parse --show-toplevel)"

# Lefthook gets its own build dir; the generated .git/hooks stub hardcodes this path.
# --disable-sandbox: installing hooks writes to .git/, which the plugin sandbox blocks.
swift package --build-path .build/lefthook --disable-sandbox lefthook install

# Lint/format tools use a separate build dir so they never contend with Lefthook's
# SPM lock while a hook runs. SwiftLint is a prebuilt binary; SwiftFormat builds from
# source once (~10s) and is cached — warm it now so the first commit isn't slow.
echo "Preparing SwiftFormat/SwiftLint (first run builds SwiftFormat once)…"
swift run --build-path .build/tools swiftformat --version >/dev/null 2>&1 || true
swift package --build-path .build/tools resolve >/dev/null 2>&1 || true

echo "✅ Dev environment ready. Git hooks run automatically on commit."
