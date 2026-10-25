import Foundation
@testable import Lume
import Testing

/// What the casting remote shows when no player stands behind it — a session
/// resumed at launch, or one a closed player left running.
@MainActor
struct CastRemoteItemTests {
    private nonisolated static let poster = URL(string: "https://example.com/poster.jpg")

    private nonisolated static func status(
        hasMedia: Bool = true,
        duration: TimeInterval? = 3600
    ) -> CastPlaybackStatus {
        CastPlaybackStatus(
            hasMedia: hasMedia, position: 0, duration: duration, isPlaying: true,
            isBuffering: false, volume: 0.5, idleReason: nil,
            title: "Receiver Title", subtitle: "Receiver Subtitle", posterURL: poster
        )
    }

    private nonisolated static func request(_ streamType: CastMediaRequest.StreamType) -> CastMediaRequest {
        CastMediaRequest(
            contentURL: URL(fileURLWithPath: "/stream"),
            contentType: "video/mp4",
            streamType: streamType,
            title: "Request Title",
            subtitle: "S1 E1",
            posterURL: nil,
            startTime: 0,
            contentRef: .episode("e1")
        )
    }

    @Test(arguments: [
        (CastPlaybackStatus.idle, false),
        (CastRemoteItemTests.status(duration: 3600), false),
        (CastRemoteItemTests.status(duration: nil), true),
        (CastRemoteItemTests.status(hasMedia: false, duration: nil), false)
    ])
    func `a resumed session is live when the receiver reports no duration`(
        status: CastPlaybackStatus, isLive: Bool
    ) {
        let item = CastRemoteItem(status: status, request: nil, media: nil)
        #expect(item.isLive == isLive)
    }

    @Test
    func `a resumed session shows the receiver's own metadata`() {
        let item = CastRemoteItem(status: Self.status(), request: nil, media: nil)
        #expect(item.title == "Receiver Title")
        #expect(item.subtitle == "Receiver Subtitle")
        #expect(item.posterURL == Self.poster)
    }

    @Test(arguments: [CastMediaRequest.StreamType.live, .buffered])
    func `the request Lume loaded wins over the receiver's metadata`(streamType: CastMediaRequest.StreamType) {
        let item = CastRemoteItem(status: Self.status(duration: nil), request: Self.request(streamType), media: nil)
        #expect(item.title == "Request Title")
        #expect(item.subtitle == "S1 E1")
        #expect(item.isLive == (streamType == .live))
    }

    @Test
    func `the remote's clock follows the receiver while no player feeds it`() {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)
        let model = CastMiniControllerModel(castService: service) { _ in }
        provider.simulateConnection(.connected)
        provider.simulatePlaying(at: 120, duration: 3600)

        model.start()
        #expect(model.clock.current == 120)
        #expect(model.clock.duration == 3600)

        provider.simulatePlaying(at: 121, duration: 3600)
        #expect(model.clock.current == 121)

        model.stop()
        provider.simulatePlaying(at: 200, duration: 3600)
        #expect(model.clock.current == 121)
    }
}
