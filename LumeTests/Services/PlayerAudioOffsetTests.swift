import Foundation
@testable import Lume
import SwiftData
import Testing

/// The audio offset: the presets and their per-engine mapping, the playlist
/// default, and the session the full-screen player keeps on top of it.
struct PlayerAudioOffsetTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, Category.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeMedia(playlistID: UUID, kind: String = "live", offset: Int? = nil) -> PlayableMedia {
        PlayableMedia(
            id: "live-\(playlistID.uuidString)-\(kind)-1",
            url: URL(string: "http://example.com/1.m3u8")!,
            title: "Channel", subtitle: nil, posterURL: nil,
            kind: .live, startTime: 0,
            contentRef: .live("\(playlistID.uuidString)-\(kind)-1"),
            audioOffsetMilliseconds: offset
        )
    }

    // MARK: - Presets and engine mapping

    @Test func `presets are symmetric around zero and labelled with a sign`() {
        #expect(AudioOffsetPreset.values.contains(0))
        #expect(AudioOffsetPreset.values == AudioOffsetPreset.values.sorted())
        #expect(AudioOffsetPreset.values.map { -$0 }.sorted() == AudioOffsetPreset.values)
        #expect(AudioOffsetPreset.label(100) == "+100 ms")
        #expect(AudioOffsetPreset.label(-50) == "-50 ms")
        #expect(AudioOffsetPreset.label(0) == "0 ms")
    }

    @Test func `values are clamped to what the engines carry`() {
        #expect(AudioOffsetPreset.clamped(150) == 150)
        #expect(AudioOffsetPreset.clamped(5000) == 2000)
        #expect(AudioOffsetPreset.clamped(-5000) == -2000)
    }

    @Test func `vlc takes microseconds with the same sign`() {
        #expect(AudioOffsetPreset.vlcMicroseconds(100) == 100_000)
        #expect(AudioOffsetPreset.vlcMicroseconds(-250) == -250_000)
        #expect(AudioOffsetPreset.vlcMicroseconds(0) == 0)
    }

    @Test func `ksplayer takes a video delay with the opposite sign`() {
        // Audio 100 ms later == the picture 100 ms earlier.
        #expect(AudioOffsetPreset.ksPlayerVideoDelaySeconds(100) == -0.1)
        #expect(AudioOffsetPreset.ksPlayerVideoDelaySeconds(-250) == 0.25)
        #expect(AudioOffsetPreset.ksPlayerVideoDelaySeconds(0) == 0)
    }

    @Test func `aether adds the offset to its engine-wide delay and clamps`() {
        #expect(AudioOffsetPreset.aetherSeconds(engineMilliseconds: 250, offsetMilliseconds: -100) == 0.15)
        #expect(AudioOffsetPreset.aetherSeconds(engineMilliseconds: 0, offsetMilliseconds: 500) == 0.5)
        #expect(AudioOffsetPreset.aetherSeconds(engineMilliseconds: 1900, offsetMilliseconds: 500) == 2)
    }

    // MARK: - Playlist default

    @Test func `a playlist starts without an offset and media omits zero`() {
        let playlist = Playlist(name: "P", serverURL: "http://example.com", username: "u", password: "p")
        #expect(playlist.audioOffsetMilliseconds == 0)
        #expect(PlayableMedia.audioOffset(for: playlist) == nil)
        playlist.audioOffsetMilliseconds = -150
        #expect(PlayableMedia.audioOffset(for: playlist) == -150)
    }

    @Test func `media factories carry the playlist offset`() throws {
        let playlist = Playlist(name: "P", serverURL: "http://example.com:8080", username: "u", password: "p")
        playlist.audioOffsetMilliseconds = 200
        let stream = LiveStream(id: "l-1", streamId: 1, name: "News", tvArchive: 1, tvArchiveDuration: 3)
        let movie = Movie(id: "m-1", streamId: 2, name: "Film", containerExtension: "mp4")
        let episode = Episode(id: "e-1", episodeId: "3", title: "Pilot", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)

        #expect(try #require(PlayableMedia.from(stream: stream, playlist: playlist)).audioOffsetMilliseconds == 200)
        #expect(try #require(PlayableMedia.from(movie: movie, playlist: playlist)).audioOffsetMilliseconds == 200)
        #expect(try #require(PlayableMedia.from(episode: episode, playlist: playlist)).audioOffsetMilliseconds == 200)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let catchup = try #require(PlayableMedia.catchup(
            stream: stream, playlist: playlist, programTitle: "News", start: start, end: start.addingTimeInterval(60)
        ))
        #expect(catchup.audioOffsetMilliseconds == 200)
    }

    @Test func `the offset survives a codable round trip and stream hand-offs`() throws {
        let media = makeMedia(playlistID: UUID(), offset: -100)
        let decoded = try JSONDecoder().decode(PlayableMedia.self, from: JSONEncoder().encode(media))
        #expect(decoded.audioOffsetMilliseconds == -100)
        #expect(media.resuming(at: 10).audioOffsetMilliseconds == -100)
        #expect(try media.replacingURL(#require(URL(string: "http://example.com/2.m3u8"))).audioOffsetMilliseconds == -100)
    }

    // MARK: - Session

    @Test func `the session follows the provider until the viewer picks`() {
        let session = PlayerAudioOffsetSession()
        let playlistID = UUID()
        session.update(for: makeMedia(playlistID: playlistID, offset: 100))
        #expect(session.providerMilliseconds == 100)
        #expect(session.effectiveMilliseconds == 100)
        #expect(session.ownerPlaylistID == playlistID)
        #expect(!session.hasSessionOverride)

        session.select(300)
        #expect(session.effectiveMilliseconds == 300)
        #expect(session.hasSessionOverride)

        // Picking the provider's own value is no override.
        session.select(100)
        #expect(!session.hasSessionOverride)

        session.select(-50)
        session.useProviderDefault()
        #expect(session.effectiveMilliseconds == 100)
    }

    @Test func `a pick carries to the same provider and drops on another`() {
        let session = PlayerAudioOffsetSession()
        let first = UUID()
        session.update(for: makeMedia(playlistID: first, offset: nil))
        session.select(250)

        session.update(for: makeMedia(playlistID: first, kind: "movie", offset: nil))
        #expect(session.effectiveMilliseconds == 250)

        session.update(for: makeMedia(playlistID: UUID(), offset: 50))
        #expect(session.effectiveMilliseconds == 50)
        #expect(!session.hasSessionOverride)
    }

    @Test func `a recording has no provider to save to`() throws {
        let session = PlayerAudioOffsetSession()
        try session.update(for: PlayableMedia(
            id: "rec", url: #require(URL(string: "http://example.com/r.m3u8")), title: "R", subtitle: nil, posterURL: nil,
            kind: .vod, startTime: 0, contentRef: .recording("abc")
        ))
        #expect(session.ownerPlaylistID == nil)
        #expect(session.providerMilliseconds == 0)
    }

    @Test func `only the engine that registered can clear adjustability`() {
        let session = PlayerAudioOffsetSession()
        #expect(!session.isAdjustable)
        session.register(engine: .vlcKit, isAdjustable: true)
        #expect(session.isAdjustable)
        // The torn-down KSPlayer view's unregister must not clear VLC's.
        session.unregister(engine: .ksPlayer)
        #expect(session.isAdjustable)
        session.register(engine: .ksPlayer, isAdjustable: false)
        #expect(session.isAdjustable)
        session.unregister(engine: .vlcKit)
        #expect(!session.isAdjustable)
    }

    @Test func `saving writes the value onto the owning playlist`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "P", serverURL: "http://example.com", username: "u", password: "p")
        context.insert(playlist)
        try context.save()

        let session = PlayerAudioOffsetSession()
        session.update(for: makeMedia(playlistID: playlist.id, offset: nil))
        session.select(150)
        #expect(session.saveAsProviderDefault(in: context))
        #expect(playlist.audioOffsetMilliseconds == 150)
        #expect(session.providerMilliseconds == 150)
        #expect(session.effectiveMilliseconds == 150)
        #expect(!session.hasSessionOverride)

        // An unknown playlist leaves everything as it was.
        let orphan = PlayerAudioOffsetSession()
        orphan.update(for: makeMedia(playlistID: UUID(), offset: nil))
        orphan.select(50)
        #expect(!orphan.saveAsProviderDefault(in: context))
        #expect(orphan.effectiveMilliseconds == 50)
    }
}
