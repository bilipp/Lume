#!/bin/sh
# Patches up KSPlayer / FFmpegKit XCFramework slices so they can be embedded:
#   1. iOS: rewrite CFBundleIdentifiers that contain underscores (iOS rejects
#      `_` in embedded-framework bundle IDs).
#   2. macOS: convert shallow framework layout (Info.plist + binary at the
#      root) into the deep layout (Versions/A/...) that macOS requires.
#
# Runs early in the Lume target build, before Sources / Frameworks. Patches
# both the source XCFramework slices (so subsequent extractions are correct)
# and any framework already staged in BUILT_PRODUCTS_DIR (so this build can
# finish).
set -e

# ---- helpers -----------------------------------------------------------------

# Set to 1 by fix_bundle_id when it actually rewrites a bundle id, so callers
# only re-sign the frameworks that changed.
BUNDLE_ID_PATCHED=0

fix_bundle_id() {
    plist="$1"
    [ -f "$plist" ] || return 0
    current=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || echo "")
    case "$current" in
        *_*)
            fixed=$(echo "$current" | tr '_' '-')
            chmod u+w "$plist" 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $fixed" "$plist"
            BUNDLE_ID_PATCHED=1
            echo "[fix-ksplayer] CFBundleIdentifier patched in $plist ($current -> $fixed)"
            ;;
    esac
}

resign_framework() {
    # Re-seal a framework so its code-signature identifier matches the
    # (already underscore-free) CFBundleIdentifier. fix_bundle_id rewrites the
    # plist *after* the package build signed the bundle, so the signature keeps
    # the original `..._combined` identifier while the plist says `...-combined`.
    # App Store upload then fails with error 90334 (identifier mismatch), since
    # export re-signs with --preserve-metadata=identifier and carries the stale
    # id forward. Forcing --identifier here fixes it at the source.
    fw="$1"
    [ -d "$fw" ] || return 0
    [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] || return 0
    identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    [ -n "$identity" ] || return 0

    if [ -f "$fw/Versions/Current/Resources/Info.plist" ]; then
        plist="$fw/Versions/Current/Resources/Info.plist"
    elif [ -f "$fw/Resources/Info.plist" ]; then
        plist="$fw/Resources/Info.plist"
    else
        plist="$fw/Info.plist"
    fi
    [ -f "$plist" ] || return 0

    bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || echo "")
    [ -n "$bid" ] || return 0

    chmod -R u+w "$fw" 2>/dev/null || true
    codesign --force \
        --sign "$identity" \
        --identifier "$bid" \
        --preserve-metadata=entitlements,flags \
        --timestamp=none \
        "$fw"
    echo "[fix-ksplayer] re-signed $(basename "$fw") with identifier $bid"
}

process_framework() {
    # $2 == 1 -> re-sign after patching (staged / embedded copies that Xcode
    # ships); the source XCFramework slice (0) is re-signed by Xcode on embed.
    fw="$1"
    do_resign="${2:-0}"
    [ -d "$fw" ] || return 0
    BUNDLE_ID_PATCHED=0
    if is_macos_build; then
        restructure_to_deep_bundle "$fw"
        fix_bundle_id "$fw/Versions/A/Resources/Info.plist"
    else
        fix_bundle_id "$fw/Info.plist"
    fi
    # Only re-seal the bundle when we actually changed its id — re-signing every
    # embedded framework is unnecessary (and slow for the big VLCKit slices).
    [ "$do_resign" = "1" ] && [ "$BUNDLE_ID_PATCHED" = "1" ] && resign_framework "$fw"
    return 0
}

restructure_to_deep_bundle() {
    fw="$1"
    [ -d "$fw" ] || return 0
    # Already deep — leave alone.
    [ -d "$fw/Versions" ] && return 0

    fw_name=$(basename "$fw" .framework)
    binary="$fw/$fw_name"
    # No binary at top level means it's already structured some other way.
    [ -f "$binary" ] || return 0

    chmod -R u+w "$fw" 2>/dev/null || true
    mkdir -p "$fw/Versions/A/Resources"

    if [ -f "$fw/Info.plist" ]; then
        mv "$fw/Info.plist" "$fw/Versions/A/Resources/Info.plist"
    fi
    if [ -d "$fw/Headers" ]; then
        mv "$fw/Headers" "$fw/Versions/A/Headers"
    fi
    if [ -d "$fw/Modules" ]; then
        mv "$fw/Modules" "$fw/Versions/A/Modules"
    fi
    if [ -d "$fw/PrivateHeaders" ]; then
        mv "$fw/PrivateHeaders" "$fw/Versions/A/PrivateHeaders"
    fi
    mv "$binary" "$fw/Versions/A/$fw_name"

    ( cd "$fw/Versions" && ln -sfh A Current )
    ( cd "$fw"
      [ -d "Versions/Current/Headers" ] && ln -sfh "Versions/Current/Headers" Headers
      [ -d "Versions/Current/Modules" ] && ln -sfh "Versions/Current/Modules" Modules
      [ -d "Versions/Current/Resources" ] && ln -sfh "Versions/Current/Resources" Resources
      [ -d "Versions/Current/PrivateHeaders" ] && ln -sfh "Versions/Current/PrivateHeaders" PrivateHeaders
      [ -f "Versions/Current/$fw_name" ] && ln -sfh "Versions/Current/$fw_name" "$fw_name"
    )
    echo "[fix-ksplayer] Restructured $fw to deep bundle layout"
}

# ---- locate the SwiftPM checkouts -------------------------------------------

PKG_BASE="${BUILD_DIR}/../.."
CHECKOUTS="${PKG_BASE}/SourcePackages/checkouts"

# Detect platform.
PLATFORM="${PLATFORM_NAME:-iphoneos}"

is_macos_build() {
    case "$PLATFORM" in
        macosx) return 0 ;;
        *) return 1 ;;
    esac
}

# ---- patch each XCFramework slice in the SwiftPM checkouts ------------------

if [ -d "$CHECKOUTS" ]; then
    find "$CHECKOUTS" -name "*.xcframework" -type d 2>/dev/null | while read -r xcf; do
        # Pick the slice for the platform we're building.
        if is_macos_build; then
            slice_pattern="macos-*"
        else
            case "$PLATFORM" in
                iphoneos)          slice_pattern="ios-arm64" ;;
                iphonesimulator)   slice_pattern="ios-arm64_x86_64-simulator" ;;
                xros)              slice_pattern="xros-arm64" ;;
                xrsimulator)       slice_pattern="xros-arm64-simulator" ;;
                appletvos)         slice_pattern="tvos-*" ;;
                appletvsimulator)  slice_pattern="tvos-*-simulator" ;;
                *)                 slice_pattern="*" ;;
            esac
        fi

        for slice in "$xcf"/$slice_pattern; do
            [ -d "$slice" ] || continue
            for fw in "$slice"/*.framework; do
                process_framework "$fw" 0
            done
        done
    done
fi

# ---- patch frameworks already staged in BUILT_PRODUCTS_DIR ------------------

for fw in "${BUILT_PRODUCTS_DIR}"/*.framework; do
    process_framework "$fw" 1
done

# ---- patch frameworks already embedded into the app bundle ------------------
# (only the embedded copy gets validated; if we got here on an incremental
# build, the app's existing Frameworks dir may still hold a stale slice)

EMBED_DIR=""
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${FRAMEWORKS_FOLDER_PATH:-}" ]; then
    EMBED_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
fi
if [ -n "$EMBED_DIR" ] && [ -d "$EMBED_DIR" ]; then
    for fw in "$EMBED_DIR"/*.framework; do
        process_framework "$fw" 1
    done
fi
