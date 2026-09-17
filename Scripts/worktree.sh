#!/bin/bash
set -euo pipefail

cp ../../../Lume/.env .env
cp -R ../../../Lume/.claude/ .claude/
./Scripts/setup.sh
# FFmpeg.xcframework (LumeEngine) ships arm64 slices only, so pin the arch —
# a bare `generic/platform=iOS Simulator` also builds x86_64 and fails to link.
xcodebuild build -scheme Lume -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
  -clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM -quiet
