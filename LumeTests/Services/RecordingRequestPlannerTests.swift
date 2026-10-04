import Foundation
@testable import Lume
import LumeRecorderKit
import Testing

/// The pure recording rules: windows and padding, `sourceRef` round-trips,
/// idempotency keys, parental filtering and which sources can record.
struct RecordingRequestPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let streamURL = URL(string: "http://example.com/live/u/p/42.m3u8")!
    private let playlistID = UUID(uuidString: "6F2C1D7E-3B4A-4C5D-8E9F-0A1B2C3D4E5F")!

    private var sourceRef: RecordingSourceRef {
        RecordingSourceRef(playlistID: playlistID, streamID: "\(playlistID.uuidString)-live-42")
    }

    private var channel: RecordingRequestPlanner.Channel {
        RecordingRequestPlanner.Channel(
            name: "News 24",
            logoURL: URL(string: "http://example.com/logo.png"),
            sourceRef: sourceRef
        )
    }

    private func programme(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        title: String = "Evening News",
        description: String? = "Headlines."
    ) -> RecordingRequestPlanner.Programme {
        RecordingRequestPlanner.Programme(
            title: title,
            description: description,
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(endOffset)
        )
    }

    private func recording(
        status: RecordingStatus,
        sourceRef: String?,
        id: UUID = UUID()
    ) -> Recording {
        Recording(
            id: id,
            title: "Show",
            sourceRef: sourceRef,
            start: now,
            end: now.addingTimeInterval(3600),
            status: status,
            createdAt: now
        )
    }

    // MARK: - Timing

    @Test func `classifies live upcoming and ended programmes`() {
        #expect(RecordingRequestPlanner.timing(of: programme(startOffset: -600, endOffset: 600), now: now) == .live)
        #expect(RecordingRequestPlanner.timing(of: programme(startOffset: 0, endOffset: 600), now: now) == .live)
        #expect(RecordingRequestPlanner.timing(of: programme(startOffset: 60, endOffset: 600), now: now) == .upcoming)
        #expect(RecordingRequestPlanner.timing(of: programme(startOffset: -600, endOffset: 0), now: now) == .ended)
    }

    // MARK: - Record now

    @Test func `record now runs from now to programme end plus five minutes`() throws {
        let airing = programme(startOffset: -1200, endOffset: 1800)
        let plan = try #require(RecordingRequestPlanner.recordNow(
            streamURL: streamURL, channel: channel, programme: airing, now: now
        ))
        #expect(plan.request.start == now)
        #expect(plan.request.end == airing.end.addingTimeInterval(5 * 60))
        #expect(plan.request.title == "Evening News")
        #expect(plan.request.programmeDescription == "Headlines.")
        #expect(plan.request.channelName == "News 24")
        #expect(plan.request.channelLogoURL == URL(string: "http://example.com/logo.png"))
        #expect(plan.request.streamURL == streamURL)
        #expect(plan.request.sourceRef == sourceRef.rawValue)
    }

    @Test func `record now without EPG asks for a duration`() {
        #expect(RecordingRequestPlanner.recordNowWindow(programme: nil, now: now) == nil)
        #expect(RecordingRequestPlanner.recordNow(
            streamURL: streamURL, channel: channel, programme: nil, now: now
        ) == nil)
    }

    @Test func `record now from an upcoming or ended programme asks for a duration`() {
        #expect(RecordingRequestPlanner.recordNowWindow(programme: programme(startOffset: 60, endOffset: 600), now: now) == nil)
        #expect(RecordingRequestPlanner.recordNowWindow(programme: programme(startOffset: -600, endOffset: -1), now: now) == nil)
    }

    @Test(arguments: RecordingRequestPlanner.FallbackDuration.allCases)
    func `fallback duration runs from now for the chosen length`(duration: RecordingRequestPlanner.FallbackDuration) {
        let plan = RecordingRequestPlanner.recordNow(streamURL: streamURL, channel: channel, duration: duration, now: now)
        #expect(plan.request.start == now)
        #expect(plan.request.end == now.addingTimeInterval(TimeInterval(duration.rawValue) * 60))
        #expect(plan.request.title == "News 24")
        #expect(plan.request.programmeDescription == nil)
    }

    @Test func `fallback durations are thirty sixty and one hundred twenty minutes`() {
        #expect(RecordingRequestPlanner.FallbackDuration.allCases.map(\.rawValue) == [30, 60, 120])
    }

    // MARK: - Schedule

    @Test func `schedule pads two minutes before and five after`() throws {
        let upcoming = programme(startOffset: 3600, endOffset: 7200)
        let plan = try #require(RecordingRequestPlanner.schedule(
            streamURL: streamURL, channel: channel, programme: upcoming, now: now
        ))
        #expect(plan.request.start == upcoming.start.addingTimeInterval(-2 * 60))
        #expect(plan.request.end == upcoming.end.addingTimeInterval(5 * 60))
        #expect(plan.request.title == "Evening News")
    }

    @Test func `schedule refuses a programme already on air or over`() {
        #expect(RecordingRequestPlanner.schedule(
            streamURL: streamURL, channel: channel, programme: programme(startOffset: -60, endOffset: 600), now: now
        ) == nil)
        #expect(RecordingRequestPlanner.schedule(
            streamURL: streamURL, channel: channel, programme: programme(startOffset: -600, endOffset: -60), now: now
        ) == nil)
    }

    @Test func `blank programme title falls back to the channel name`() throws {
        let untitled = programme(startOffset: -60, endOffset: 600, title: "  ", description: "   ")
        let plan = try #require(RecordingRequestPlanner.recordNow(
            streamURL: streamURL, channel: channel, programme: untitled, now: now
        ))
        #expect(plan.request.title == "News 24")
        #expect(plan.request.programmeDescription == nil)
    }

    // MARK: - sourceRef

    @Test func `sourceRef has the documented format`() {
        let ref = RecordingSourceRef(playlistID: playlistID, streamID: "abc")
        #expect(ref.rawValue == "6F2C1D7E-3B4A-4C5D-8E9F-0A1B2C3D4E5F:live:abc")
    }

    @Test func `sourceRef round-trips including colons in the stream id`() {
        for streamID in ["\(playlistID.uuidString)-live-42", "a:b:c", "x"] {
            let ref = RecordingSourceRef(playlistID: playlistID, streamID: streamID)
            #expect(RecordingSourceRef(rawValue: ref.rawValue) == ref)
        }
    }

    @Test func `sourceRef built from catalog rows uses their ids`() {
        let playlist = Playlist(name: "X", serverURL: "http://example.com", username: "u", password: "p")
        let stream = LiveStream(id: "\(playlist.id.uuidString)-live-9", streamId: 9, name: "C")
        let ref = RecordingSourceRef(stream: stream, playlist: playlist)
        #expect(ref.playlistID == playlist.id)
        #expect(ref.streamID == stream.id)
    }

    @Test(arguments: [
        "",
        "live",
        "not-a-uuid:live:42",
        "6F2C1D7E-3B4A-4C5D-8E9F-0A1B2C3D4E5F:movie:42",
        "6F2C1D7E-3B4A-4C5D-8E9F-0A1B2C3D4E5F:live:",
        "6F2C1D7E-3B4A-4C5D-8E9F-0A1B2C3D4E5F:live",
        "lume:42:abc"
    ])
    func `malformed sourceRef parses to nil`(raw: String) {
        #expect(RecordingSourceRef(rawValue: raw) == nil)
    }

    // MARK: - Idempotency

    @Test func `idempotency key is stable per action and distinct across actions`() {
        let action = UUID()
        #expect(RecordingRequestPlanner.idempotencyKey(for: action) == RecordingRequestPlanner.idempotencyKey(for: action))
        #expect(RecordingRequestPlanner.idempotencyKey(for: action) != RecordingRequestPlanner.idempotencyKey(for: UUID()))
    }

    @Test func `a plan carries the key of its action`() throws {
        let action = UUID()
        let airing = programme(startOffset: -60, endOffset: 600)
        let first = try #require(RecordingRequestPlanner.recordNow(
            streamURL: streamURL, channel: channel, programme: airing, now: now, actionID: action
        ))
        let again = try #require(RecordingRequestPlanner.recordNow(
            streamURL: streamURL, channel: channel, programme: airing, now: now, actionID: action
        ))
        let other = try #require(RecordingRequestPlanner.recordNow(
            streamURL: streamURL, channel: channel, programme: airing, now: now
        ))
        #expect(first.idempotencyKey == RecordingRequestPlanner.idempotencyKey(for: action))
        #expect(first.idempotencyKey == again.idempotencyKey)
        #expect(first.idempotencyKey != other.idempotencyKey)
    }

    // MARK: - Matching

    @Test func `active recording matches its channel only while capturing`() {
        let running = recording(status: .recording, sourceRef: sourceRef.rawValue)
        let done = recording(status: .completed, sourceRef: sourceRef.rawValue)
        let elsewhere = recording(status: .recording, sourceRef: "\(UUID().uuidString):live:other")
        #expect(RecordingRequestPlanner.activeRecording(for: sourceRef, now: now, in: [done, elsewhere, running])?.id == running.id)
        #expect(RecordingRequestPlanner.activeRecording(for: sourceRef, now: now, in: [done, elsewhere]) == nil)
    }

    @Test func `a later schedule never turns the channel's Record into Stop`() {
        let tonight = windowed(.scheduled, start: 3 * 3600, end: 4 * 3600)
        #expect(RecordingRequestPlanner.activeRecording(for: sourceRef, now: now, in: [tonight]) == nil)
        #expect(!RecordingRequestPlanner.isCapturing(tonight, now: now))
    }

    @Test func `a schedule whose window has opened counts as capturing`() {
        let opened = windowed(.scheduled, start: -60, end: 3600)
        let tonight = windowed(.scheduled, start: 3 * 3600, end: 4 * 3600)
        #expect(RecordingRequestPlanner.isCapturing(opened, now: now))
        #expect(RecordingRequestPlanner.activeRecording(for: sourceRef, now: now, in: [tonight, opened])?.id == opened.id)
        #expect(!RecordingRequestPlanner.isCapturing(windowed(.scheduled, start: -3600, end: -60), now: now))
        #expect(!RecordingRequestPlanner.isCapturing(windowed(.completed, start: -60, end: 3600), now: now))
    }

    private func windowed(_ status: RecordingStatus, start: TimeInterval, end: TimeInterval) -> Recording {
        Recording(
            id: UUID(),
            title: "Show",
            sourceRef: sourceRef.rawValue,
            start: now.addingTimeInterval(start),
            end: now.addingTimeInterval(end),
            status: status,
            createdAt: now
        )
    }

    private func pending(
        for programme: RecordingRequestPlanner.Programme?,
        in recordings: [Recording]
    ) -> Recording? {
        RecordingRequestPlanner.pendingRecording(for: sourceRef, programme: programme, now: now, in: recordings)
    }

    @Test func `a schedule matches its own programme, not its neighbours`() {
        let onAir = programme(startOffset: -1800, endOffset: 600)
        let next = programme(startOffset: 600, endOffset: 4200)
        let later = programme(startOffset: 4200, endOffset: 7800)
        let window = RecordingRequestPlanner.scheduleWindow(programme: next)
        let scheduled = windowed(
            .scheduled,
            start: window.start.timeIntervalSince(now),
            end: window.end.timeIntervalSince(now)
        )
        #expect(pending(for: next, in: [scheduled])?.id == scheduled.id)
        #expect(pending(for: onAir, in: [scheduled]) == nil)
        #expect(pending(for: later, in: [scheduled]) == nil)
    }

    @Test func `record now matches the programme on air`() throws {
        let onAir = programme(startOffset: -1800, endOffset: 600)
        let window = try #require(RecordingRequestPlanner.recordNowWindow(programme: onAir, now: now))
        let running = windowed(.recording, start: 0, end: window.end.timeIntervalSince(now))
        #expect(pending(for: onAir, in: [running])?.id == running.id)
        #expect(pending(for: programme(startOffset: 600, endOffset: 4200), in: [running]) == nil)
    }

    @Test func `an upcoming programme's schedule matches it but is not capturing`() {
        let next = programme(startOffset: 3600, endOffset: 7200)
        let window = RecordingRequestPlanner.scheduleWindow(programme: next)
        let scheduled = windowed(
            .scheduled,
            start: window.start.timeIntervalSince(now),
            end: window.end.timeIntervalSince(now)
        )
        let match = pending(for: next, in: [scheduled])
        #expect(match?.id == scheduled.id)
        #expect(match.map { RecordingRequestPlanner.isCapturing($0, now: now) } == false)
        // Neither the programme on air nor a live gap picks up the later schedule.
        #expect(pending(for: programme(startOffset: -600, endOffset: 3600), in: [scheduled]) == nil)
        #expect(pending(for: nil, in: [scheduled]) == nil)
    }

    @Test func `the live programme's opened schedule matches and is capturing`() {
        let onAir = programme(startOffset: -60, endOffset: 1800)
        let window = RecordingRequestPlanner.scheduleWindow(programme: onAir)
        let scheduled = windowed(
            .scheduled,
            start: window.start.timeIntervalSince(now),
            end: window.end.timeIntervalSince(now)
        )
        let match = pending(for: onAir, in: [scheduled])
        #expect(match?.id == scheduled.id)
        #expect(match.map { RecordingRequestPlanner.isCapturing($0, now: now) } == true)
    }

    @Test func `a running capture covers the programme on air and a live gap`() {
        let fallback = windowed(.recording, start: -600, end: 6600)
        #expect(pending(for: programme(startOffset: -300, endOffset: 1500), in: [fallback])?.id == fallback.id)
        #expect(pending(for: nil, in: [fallback])?.id == fallback.id)
        #expect(pending(for: programme(startOffset: 1500, endOffset: 3300), in: [fallback]) == nil)
        #expect(pending(for: nil, in: [windowed(.completed, start: -600, end: 6600)]) == nil)
    }

    // MARK: - Parental

    @Test func `child profile hides recordings from restricted categories`() {
        let restrictedRef = RecordingSourceRef(playlistID: playlistID, streamID: "restricted")
        let openRef = RecordingSourceRef(playlistID: playlistID, streamID: "open")
        let restricted = recording(status: .completed, sourceRef: restrictedRef.rawValue)
        let open = recording(status: .completed, sourceRef: openRef.rawValue)
        let unmatched = recording(status: .completed, sourceRef: "\(playlistID.uuidString):live:gone")
        let foreign = recording(status: .completed, sourceRef: "opaque")
        let unreferenced = recording(status: .completed, sourceRef: nil)
        let categories = ["restricted": "adult", "open": "news"]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["adult"])

        let visible = RecordingRequestPlanner.visibleRecordings(
            [restricted, open, unmatched, foreign, unreferenced],
            restriction: restriction,
            categoryID: { categories[$0.streamID] }
        )
        #expect(visible.map(\.id) == [open.id, unmatched.id, foreign.id, unreferenced.id])
    }

    @Test func `adult profile and hidden categories keep every recording`() {
        let ref = RecordingSourceRef(playlistID: playlistID, streamID: "s")
        let item = recording(status: .completed, sourceRef: ref.rawValue)
        let parent = ContentRestriction(isActive: false, restrictedCategoryIDs: ["adult"], hiddenCategoryIDs: ["adult"])
        let childHidden = ContentRestriction(isActive: true, restrictedCategoryIDs: [], hiddenCategoryIDs: ["adult"])
        for restriction in [parent, childHidden] {
            let visible = RecordingRequestPlanner.visibleRecordings([item], restriction: restriction) { _ in "adult" }
            #expect(visible.map(\.id) == [item.id])
        }
    }

    // MARK: - Source support

    private static let allSourceTypes: [PlaylistSourceType] = [.xtream, .m3u, .stalker, .webdav, .jellyfin, .plex, .emby]

    /// Exhaustive on purpose: a new source type fails to compile here until its
    /// recording support is decided.
    private static func expectedSupport(_ type: PlaylistSourceType) -> (record: Bool, schedule: Bool) {
        switch type {
        case .xtream, .m3u: (true, true)
        case .stalker: (true, false)
        case .webdav, .jellyfin, .plex, .emby: (false, false)
        }
    }

    @Test(arguments: allSourceTypes)
    func `recording support per source type`(type: PlaylistSourceType) {
        let expected = Self.expectedSupport(type)
        #expect(type.supportsRecording == expected.record)
        #expect(type.supportsRecordingSchedule == expected.schedule)
    }

    @Test func `scheduling implies recording`() {
        for type in Self.allSourceTypes where type.supportsRecordingSchedule {
            #expect(type.supportsRecording)
        }
    }

    @Test func `recording server is a premium feature`() {
        #expect(PremiumFeature.allCases.contains(.recordingServer))
        #expect(PremiumFeature.recordingServer.title.key == "Recording Server")
        #expect(PremiumFeature.recordingServer.systemImage == "record.circle")
    }
}
