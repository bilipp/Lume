#!/bin/bash

cp ../../../Lume/.env .env
cp -R ../../../Lume/.claude/ .claude/
./Scripts/setup.sh
# Private DerivedData per worktree: without it this build shares Xcode's own
# DerivedData for the project, and re-resolving the package graph underneath an
# open Xcode leaves it stuck on "Missing package product 'LumeEngine'".
# Pair it with the shared package clone (see CLAUDE.md) so each dir does not
# re-clone the 6.4 GB package graph.
DD="/tmp/lume-dd-$(basename "$PWD")"
# FFmpeg.xcframework (LumeEngine) ships arm64 slices only, so pin the arch —
# a bare `generic/platform=iOS Simulator` also builds x86_64 and fails to link.
xcodebuild build -scheme Lume -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
  -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM -quiet
