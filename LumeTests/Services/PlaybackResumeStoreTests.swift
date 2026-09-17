import Foundation
@testable import Lume
import Testing

@MainActor
struct PlaybackResumeStoreTests {
    private func makeMedia(startTime: TimeInterval = 0) throws -> PlayableMedia {
        try PlayableMedia(
            id: "movie-42",
            url: #require(URL(string: "https://example.com/stream.mp4")),
            title: "Sample Movie",
            subtitle: "2024",
            posterURL: URL(string: "https://example.com/poster.jpg"),
            kind: .vod,
            startTime: startTime,
            contentRef: .movie("42")
        )
    }

    @Test func `round-trips the media snapshot`() throws {
        let media = try makeMedia(startTime: 321)
        PlaybackResumeStore.save(media)
        #expect(PlaybackResumeStore.load() == media)
    }

    @Test func `a later save replaces the snapshot`() throws {
        try PlaybackResumeStore.save(makeMedia())
        let resumed = try makeMedia().resuming(at: 900)
        PlaybackResumeStore.save(resumed)
        #expect(PlaybackResumeStore.load()?.startTime == 900)
    }
}
