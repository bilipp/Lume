# Replay matching evidence

`sports-replay-nfl-partial.json` combines a redacted Dispatcharr 0.33.0 recording
response and the corresponding public ESPN NFL scoreboard event, captured on
November 15, 2026. The original capture began after kickoff; its retained EPG
programme start identifies the game without pretending the capture is complete.

Recording/channel IDs and the source reference are synthetic. Credentials, paths,
private origins, task IDs, playback handles and unrelated fields are removed.
ESPN keeps only the matching/season fields; scores and result flags are omitted.
The event ID is ESPN's own, never a Sportarr identity.

Read relative to `repoRootURL(filePath:)`, following the Dispatcharr fixture
convention. Resource names are unique because Xcode flattens test resources.
