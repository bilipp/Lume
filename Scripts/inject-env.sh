#!/bin/sh
#
# inject-env.sh
#
# Reads key/value pairs from the repo-root .env file and injects the ones the
# app needs into the built product's Info.plist. This keeps secrets (like the
# TMDB token) out of source control while still making them available at
# runtime via Bundle.main.object(forInfoDictionaryKey:).
#
# Runs as the final build phase, after Info.plist processing and before
# codesigning. If .env is absent or a key is missing, the build continues —
# the dependent feature simply degrades (e.g. the Trending row hides).

set -eu

ENV_FILE="${SRCROOT}/.env"
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [ ! -f "$ENV_FILE" ]; then
    echo "warning: .env not found at $ENV_FILE — secrets not injected"
    exit 0
fi

if [ ! -f "$PLIST" ]; then
    echo "warning: Info.plist not found at $PLIST — secrets not injected"
    exit 0
fi

# Reads a value from .env: ignores comments/blank lines, trims whitespace and
# optional surrounding quotes, and strips stray carriage returns.
read_env() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$ENV_FILE" | head -n1 \
        | sed -E "s/^[^=]*=[[:space:]]*//" \
        | sed -E "s/^\"(.*)\"$/\1/" \
        | sed -E "s/^'(.*)'$/\1/" \
        | tr -d '\r'
}

# Sets (or adds) a string key in the built Info.plist.
set_plist() {
    key="$1"
    value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST"
}

TMDB_ACCESS_TOKEN="$(read_env TMDB_ACCESS_TOKEN)"
if [ -n "$TMDB_ACCESS_TOKEN" ]; then
    set_plist TMDBAccessToken "$TMDB_ACCESS_TOKEN"
    echo "Injected TMDB_ACCESS_TOKEN into Info.plist"
else
    echo "warning: TMDB_ACCESS_TOKEN not set in .env — Trending will be hidden"
fi

OMDB_API_KEY="$(read_env OMDB_API_KEY)"
if [ -n "$OMDB_API_KEY" ]; then
    set_plist OMDBAPIKey "$OMDB_API_KEY"
    echo "Injected OMDB_API_KEY into Info.plist"
else
    echo "warning: OMDB_API_KEY not set in .env — extra ratings will be hidden"
fi

INTRO_DB_API_KEY="$(read_env INTRO_DB_API_KEY)"
if [ -n "$INTRO_DB_API_KEY" ]; then
    set_plist IntroDBAPIKey "$INTRO_DB_API_KEY"
    echo "Injected INTRO_DB_API_KEY into Info.plist"
else
    echo "warning: INTRO_DB_API_KEY not set in .env — IntroDB reads still work unauthenticated"
fi

TRAKT_CLIENT_ID="$(read_env TRAKT_CLIENT_ID)"
TRAKT_CLIENT_SECRET="$(read_env TRAKT_CLIENT_SECRET)"
if [ -n "$TRAKT_CLIENT_ID" ] && [ -n "$TRAKT_CLIENT_SECRET" ]; then
    set_plist TraktClientID "$TRAKT_CLIENT_ID"
    set_plist TraktClientSecret "$TRAKT_CLIENT_SECRET"
    echo "Injected Trakt credentials into Info.plist"
else
    echo "warning: TRAKT_CLIENT_ID/SECRET not set in .env — Trakt integration will be hidden"
fi
