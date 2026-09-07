import CoreGraphics
import Foundation
@testable import Lume
import Testing

struct EPGGridBuilderTests {
    private static let windowStart = Date(timeIntervalSince1970: 1_700_000_000)

    private static let timeline = EPGTimeline(
        start: windowStart,
        end: windowStart.addingTimeInterval(4 * 3600),
        pointsPerMinute: 6
    )

    private static func listing(
        _ id: String,
        _ title: String,
        startMinutes: Double,
        endMinutes: Double
    ) -> EPGWindowListing {
        EPGWindowListing(
            id: id,
            title: title,
            detail: "",
            start: windowStart.addingTimeInterval(startMinutes * 60),
            end: windowStart.addingTimeInterval(endMinutes * 60)
        )
    }

    private static func cells(_ listings: [EPGWindowListing]) -> [EPGProgramCell] {
        EPGGridBuilder.cells(for: listings, timeline: timeline)
    }

    /// Every row must stay a single edge-to-edge strip: sorted, disjoint, and
    /// spanning exactly the window — that is what stops blocks drawing on top
    /// of each other.
    private static func expectTiled(_ cells: [EPGProgramCell], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(cells.first?.start == timeline.start, sourceLocation: sourceLocation)
        #expect(cells.last?.end == timeline.end, sourceLocation: sourceLocation)
        for (previous, next) in zip(cells, cells.dropFirst()) {
            #expect(previous.end == next.start, sourceLocation: sourceLocation)
        }
        let total = cells.reduce(0) { $0 + $1.width }
        #expect(abs(total - timeline.totalWidth) < 0.001, sourceLocation: sourceLocation)
    }

    @Test func `disjoint listings tile with gap fillers around them`() {
        let cells = Self.cells([
            Self.listing("a", "First", startMinutes: 30, endMinutes: 60),
            Self.listing("b", "Second", startMinutes: 90, endMinutes: 120)
        ])

        Self.expectTiled(cells)
        #expect(cells.map(\.isGap) == [true, false, true, false, true])
        #expect(cells.compactMap { $0.isGap ? nil : $0.title } == ["First", "Second"])
    }

    @Test func `overlapping listings never occupy the same span`() {
        // The reported shape: a second source's 13:27 programme landing inside
        // the first source's 13:00-13:30 block.
        let cells = Self.cells([
            Self.listing("a", "First", startMinutes: 0, endMinutes: 30),
            Self.listing("b", "Second", startMinutes: 27, endMinutes: 60)
        ])

        Self.expectTiled(cells)
        let programmes = cells.filter { !$0.isGap }
        #expect(programmes.map(\.title) == ["First", "Second"])
        #expect(programmes[0].end == programmes[1].start)
        #expect(programmes[1].start == Self.windowStart.addingTimeInterval(30 * 60))
    }

    @Test func `a listing contained in the previous one is dropped, not rewound`() {
        // Cursor regression used to emit a backwards gap after the container.
        let cells = Self.cells([
            Self.listing("a", "Long", startMinutes: 0, endMinutes: 120),
            Self.listing("b", "Inside", startMinutes: 30, endMinutes: 60),
            Self.listing("c", "After", startMinutes: 120, endMinutes: 180)
        ])

        Self.expectTiled(cells)
        #expect(cells.compactMap { $0.isGap ? nil : $0.title } == ["Long", "After"])
    }

    @Test func `unsorted listings are ordered before tiling`() {
        let cells = Self.cells([
            Self.listing("c", "Third", startMinutes: 120, endMinutes: 180),
            Self.listing("a", "First", startMinutes: 0, endMinutes: 60),
            Self.listing("b", "Second", startMinutes: 60, endMinutes: 120)
        ])

        Self.expectTiled(cells)
        #expect(cells.compactMap { $0.isGap ? nil : $0.title } == ["First", "Second", "Third"])
    }

    @Test func `listings sharing a start emit the shorter one first`() {
        let cells = Self.cells([
            Self.listing("long", "Long", startMinutes: 0, endMinutes: 120),
            Self.listing("short", "Short", startMinutes: 0, endMinutes: 30)
        ])

        Self.expectTiled(cells)
        #expect(cells.compactMap { $0.isGap ? nil : $0.title } == ["Short", "Long"])
    }

    @Test func `a sliver left by trimming is discarded`() {
        let cells = Self.cells([
            Self.listing("a", "First", startMinutes: 0, endMinutes: 60),
            Self.listing("b", "Sliver", startMinutes: 59, endMinutes: 60.5),
            Self.listing("c", "Third", startMinutes: 60, endMinutes: 120)
        ])

        Self.expectTiled(cells)
        #expect(cells.compactMap { $0.isGap ? nil : $0.title } == ["First", "Third"])
    }

    @Test func `listings outside the window are clamped away`() {
        let cells = Self.cells([
            Self.listing("before", "Before", startMinutes: -120, endMinutes: -30),
            Self.listing("across", "Across", startMinutes: -30, endMinutes: 60),
            Self.listing("after", "After", startMinutes: 300, endMinutes: 360)
        ])

        Self.expectTiled(cells)
        #expect(cells.compactMap { $0.isGap ? nil : $0.title } == ["Across"])
        #expect(cells.first?.start == Self.timeline.start)
    }

    @Test func `a channel with no listings is one full-window gap`() {
        let cells = Self.cells([])

        Self.expectTiled(cells)
        #expect(cells.count == 1)
        #expect(cells[0].isGap)
    }

    // MARK: - rows(streams:cellsByChannel:timeline:)

    @MainActor
    private static func row(for stream: LiveStream) -> EPGChannelRow? {
        EPGGridBuilder.rows(streams: [stream], cellsByChannel: [:], timeline: timeline).first
    }

    /// The row snapshot and the player's own check must answer identically for
    /// the same channel and instant — a divergence is a clock icon whose tap
    /// does nothing.
    @MainActor
    private static func expectAgreement(
        _ row: EPGChannelRow,
        _ stream: LiveStream,
        start: Date,
        now: Date,
        replayable: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(row.isReplayable(start: start, now: now) == replayable, sourceLocation: sourceLocation)
        #expect(
            row.isReplayable(start: start, now: now)
                == PlayableMedia.isCatchupAvailable(stream: stream, start: start, now: now),
            sourceLocation: sourceLocation
        )
    }

    @MainActor
    @Test func `an xtream archive channel is replayable inside its window`() throws {
        let stream = LiveStream(id: "row-xtream", streamId: 1, name: "Archive",
                                tvArchive: 1, tvArchiveDuration: 7)
        let row = try #require(Self.row(for: stream))
        let now = Self.windowStart

        #expect(row.catchupCapable)
        #expect(row.archiveDays == 7)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-3 * 86400), now: now, replayable: true)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-8 * 86400), now: now, replayable: false)
    }

    @MainActor
    @Test func `an m3u channel with catchup attributes is replayable`() throws {
        let stream = LiveStream(id: "row-m3u", streamId: 2, name: "Flussonic",
                                tvArchive: 1, tvArchiveDuration: 3,
                                catchupTypeRaw: "flussonic")
        stream.directURL = "http://example.com/ch/video.m3u8"
        let row = try #require(Self.row(for: stream))
        let now = Self.windowStart

        #expect(row.catchupCapable)
        #expect(row.archiveDays == 3)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-86400), now: now, replayable: true)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-4 * 86400), now: now, replayable: false)
    }

    @MainActor
    @Test func `a deep archive row uses the guide's clamped window`() throws {
        let stream = LiveStream(id: "row-deep", streamId: 4, name: "Deep",
                                tvArchive: 1, tvArchiveDuration: 30,
                                catchupTypeRaw: "flussonic")
        stream.directURL = "http://example.com/ch/video.m3u8"
        let row = try #require(Self.row(for: stream))

        #expect(row.catchupCapable)
        #expect(row.archiveDays == PlayableMedia.guideArchiveWindowDays(for: stream))
        #expect(row.archiveDays == PlayableMedia.maxGuideArchiveDays)
    }

    @MainActor
    @Test func `an m3u channel without catchup attributes is not replayable`() throws {
        let stream = LiveStream(id: "row-m3u-bare", streamId: 3, name: "Plain",
                                tvArchive: 1, tvArchiveDuration: 7)
        stream.directURL = "http://example.com/ch/video.m3u8"
        let row = try #require(Self.row(for: stream))
        let now = Self.windowStart

        #expect(!row.catchupCapable)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-3600), now: now, replayable: false)
    }

    @MainActor
    @Test func `a channel of unknown archive depth uses the guessed window`() throws {
        let stream = LiveStream(id: "row-unknown", streamId: 4, name: "Depthless",
                                tvArchive: 1, tvArchiveDuration: 0,
                                catchupTypeRaw: "fs")
        stream.directURL = "http://example.com/ch/video.m3u8"
        let row = try #require(Self.row(for: stream))
        let now = Self.windowStart
        let unknown = TimeInterval(PlayableMedia.unknownArchiveDays) * 86400

        #expect(row.catchupCapable)
        #expect(row.archiveDays == PlayableMedia.unknownArchiveDays)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-2 * 86400), now: now, replayable: true)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-unknown + 3600), now: now, replayable: true)
        Self.expectAgreement(row, stream, start: now.addingTimeInterval(-unknown - 3600), now: now, replayable: false)
    }

    @Test func `cell ids stay unique so the grid can identify them`() {
        let cells = Self.cells([
            Self.listing("a", "First", startMinutes: 0, endMinutes: 30),
            Self.listing("b", "Second", startMinutes: 15, endMinutes: 90),
            Self.listing("c", "Third", startMinutes: 60, endMinutes: 150)
        ])

        #expect(Set(cells.map(\.id)).count == cells.count)
    }
}
