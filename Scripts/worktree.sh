
cp ../../../Lume/.env .env
cp -R ../../../Lume/.claude/ .claude/
./Scripts/setup.sh
xcodebuild build -scheme Lume -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -clonedSourcePackagesDirPath ~/Library/Developer/Lume-SharedSPM -quiet
