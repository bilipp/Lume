import Foundation
@testable import Lume
import Testing

/// `LiveSurfScope` rides on `PlayableMedia` so Combined favorites and recents
/// surfing keeps walking every member after a resume, an engine hand-off or a
/// stream swap.
struct PlayableMediaSurfScopeTests {
    /// A resume snapshot or restored macOS window written before Combined
    /// existed has no `surfScope` key and must still decode.
    @Test func `legacy snapshot without a surf scope decodes`() throws {
        let legacy = Data("""
        {
          "id": "live-l-3",
          "url": "http://example.com/live.m3u8",
          "title": "Live",
          "kind": { "live": {} },
          "startTime": 0,
          "contentRef": { "live": { "_0": "l-3" } },
          "channelScope": { "favorites": {} }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: legacy)

        #expect(decoded.contentRef == .live("l-3"))
        #expect(decoded.channelScope == .favorites)
        #expect(decoded.surfScope == nil)
    }

    @Test func `surf scope survives a round trip and stream hand-offs`() throws {
        let members = LiveSurfScope(playlistIDs: [UUID(), UUID()])
        let media = try PlayableMedia(
            id: "live-4",
            url: #require(URL(string: "http://example.com/live.m3u8")),
            title: "Live",
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live("l-4"),
            channelScope: .favorites,
            surfScope: members
        )

        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: JSONEncoder().encode(media))

        #expect(decoded.surfScope == members)
        let other = try #require(URL(string: "http://example.com/other.m3u8"))
        #expect(media.resuming(at: 30).surfScope == members)
        #expect(media.replacingURL(other).surfScope == members)
    }
}
