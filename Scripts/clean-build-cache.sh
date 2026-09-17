#!/bin/bash
#
# Reclaims the build caches Lume and its worktrees pile up.
#
# The expensive ones are the private DerivedData dirs handed to parallel
# per-platform / per-worker builds (`-derivedDataPath /tmp/lume-dd-<label>`).
# Any such dir that is NOT also given `-clonedSourcePackagesDirPath` re-clones
# the whole package graph — KSPlayer's FFmpeg xcframeworks plus VLCKit's 865 MB
# xcframework, 6.4 GB a piece. Eight of them once filled /tmp with 65 GB.
#
# Nothing removed here is a source of truth; every path regenerates. The two
# live package checkouts are deliberately KEPT so no build has to re-download:
#   ~/Library/Developer/Lume-SharedSPM              — the shared CLI clone
#   DerivedData/Lume-*/SourcePackages               — Xcode's own clone
# and `.build/tools` is kept in every checkout because that is what the
# pre-commit hook runs SwiftFormat and SwiftLint from (rebuilding it costs
# minutes on the next commit).
#
# Usage:
#   Scripts/clean-build-cache.sh              # report only, removes nothing
#   Scripts/clean-build-cache.sh --apply      # build caches (safe, no re-download)
#   Scripts/clean-build-cache.sh --apply --deep
#       also: DeviceSupport (re-extracted on next device attach), the SwiftPM
#       download cache, unavailable simulators, and an erase of every
#       shut-down simulator (wipes installed apps and their data).
#
set -uo pipefail

APPLY=0; DEEP=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --deep)  DEEP=1 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg (see --help)" >&2; exit 2 ;;
  esac
done

DD="$HOME/Library/Developer/Xcode/DerivedData"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Every checkout that owns a .build: the main clone plus each live worktree.
# Read them from git rather than guessing a layout — this script may itself be
# invoked from inside a worktree.
checkouts() {
  git -C "$REPO" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print substr($0,10)}'
}

avail() { df -k /System/Volumes/Data | awk 'NR==2{print $4}'; }
size()  { [ -e "$1" ] && du -sh "$1" 2>/dev/null | cut -f1 || echo "-"; }

# A build in flight would have its DerivedData yanked out from under it.
if pgrep -qx xcodebuild; then
  echo "xcodebuild is running — refusing to delete DerivedData underneath it." >&2
  exit 1
fi

BEFORE=$(avail)
[ "$APPLY" = 1 ] || echo "DRY RUN — nothing will be deleted. Re-run with --apply."
echo

drop() { # drop <label> <path>...
  local label="$1"; shift
  for p in "$@"; do
    [ -e "$p" ] || continue
    printf '  %-8s %-58s %s\n' "$( [ "$APPLY" = 1 ] && echo remove || echo would )" "${p/#$HOME/~}" "$(size "$p")"
    [ "$APPLY" = 1 ] && rm -rf "$p"
  done
}

echo "== private per-build DerivedData (/tmp/lume-dd-*) =="
# shellcheck disable=SC2012
shopt -s nullglob
drop dd /private/tmp/lume-dd-* /tmp/lume-dd-* /private/tmp/lume-perf-dd
shopt -u nullglob
echo

echo "== Xcode DerivedData =="
shopt -s nullglob
for d in "$DD"/Lume-*; do
  # Keep SourcePackages (6.4 GB of package checkouts); drop the rest.
  if [ -d "$d/SourcePackages" ]; then
    drop dd "$d/Index.noindex" "$d/Build" "$d/Logs" "$d/SymbolCache" "$d/TextIndex"
  else
    drop dd "$d"
  fi
done
shopt -u nullglob
drop dd "$DD/ModuleCache.noindex" "$DD/SDKStatCaches.noindex" \
        "$DD/CompilationCache.noindex" "$DD/SymbolCache.noindex"
echo

echo "== .build in the repo and every worktree (keeping .build/tools) =="
shopt -s nullglob
while read -r root; do
  [ -n "$root" ] && [ -d "$root/.build" ] || continue
  for e in "$root"/.build/*; do
    case "$(basename "$e")" in
      tools|workspace-state.json) ;;
      *) drop build "$e" ;;
    esac
  done
done < <(checkouts)
shopt -u nullglob
echo

echo "== stale git worktree registrations =="
if [ "$APPLY" = 1 ]; then git -C "$REPO" worktree prune -v; else git -C "$REPO" worktree prune -n -v; fi
echo

if [ "$DEEP" = 1 ]; then
  echo "== deep: DeviceSupport + SwiftPM download cache =="
  shopt -s nullglob
  drop deep "$HOME/Library/Developer/Xcode/iOS DeviceSupport"/* \
            "$HOME/Library/Developer/Xcode/tvOS DeviceSupport"/* \
            "$HOME/Library/Caches/org.swift.swiftpm"
  shopt -u nullglob
  echo
  echo "== deep: simulators =="
  if [ "$APPLY" = 1 ]; then
    xcrun simctl delete unavailable
    # Erase only shut-down devices; a booted one is in active use.
    xcrun simctl list devices -j \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
print("\n".join(v["udid"] for r in d.values() for v in r if v.get("state")=="Shutdown" and v.get("isAvailable")))' \
      | while read -r u; do [ -n "$u" ] && xcrun simctl erase "$u"; done
    echo "  erased every shut-down simulator; booted ones left alone"
  else
    echo "  would delete unavailable simulators and erase every shut-down one"
  fi
  echo
fi

AFTER=$(avail)
if [ "$APPLY" = 1 ]; then
  echo "reclaimed: $(( (AFTER - BEFORE) / 1024 / 1024 )) GB   (free now: $(( AFTER / 1024 / 1024 )) GB)"
else
  echo "free now: $(( AFTER / 1024 / 1024 )) GB — re-run with --apply to reclaim the above"
fi
