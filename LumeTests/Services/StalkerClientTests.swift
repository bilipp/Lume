import Foundation
@testable import Lume
import Testing

struct StalkerMACTests {
    @Test func `generated MAC is valid and uses the MAG prefix`() {
        let mac = StalkerMAC.generate()
        #expect(StalkerMAC.isValid(mac))
        #expect(mac.hasPrefix("00:1A:79"))
    }

    @Test func `generated MACs vary`() {
        // Three octets of entropy make a collision across a handful of draws
        // astronomically unlikely; this guards against a constant default.
        let macs = Set((0 ..< 8).map { _ in StalkerMAC.generate() })
        #expect(macs.count > 1)
    }

    @Test func `validation accepts well-formed and rejects malformed`() {
        #expect(StalkerMAC.isValid("00:1A:79:3F:A2:0B"))
        #expect(StalkerMAC.isValid("aa:bb:cc:dd:ee:ff"))
        #expect(!StalkerMAC.isValid("00:1A:79:3F:A2"))
        #expect(!StalkerMAC.isValid("001A793FA20B"))
        #expect(!StalkerMAC.isValid("zz:1A:79:3F:A2:0B"))
        #expect(!StalkerMAC.isValid(""))
    }
}

struct StalkerLinkTests {
    @Test func `placeholder round-trips through decode`() throws {
        let cmd = "ffmpeg http://localhost/ch/12345_"
        let url = try #require(StalkerLink.placeholder(type: .itv, cmd: cmd))
        #expect(StalkerLink.isPlaceholder(url))
        let decoded = try #require(StalkerLink.decode(url))
        #expect(decoded.type == .itv)
        #expect(decoded.cmd == cmd)
    }

    @Test func `a normal URL is not a placeholder`() throws {
        let url = try #require(URL(string: "http://example.com/stream.m3u8"))
        #expect(!StalkerLink.isPlaceholder(url))
        #expect(StalkerLink.decode(url) == nil)
    }

    @Test func `resolvedURL strips an ffmpeg prefix`() throws {
        let url = try #require(StalkerLink.resolvedURL(from: "ffmpeg http://host/live/1.ts"))
        #expect(url.absoluteString == "http://host/live/1.ts")
    }

    @Test func `resolvedURL drops trailing params after the URL`() throws {
        let url = try #require(StalkerLink.resolvedURL(from: "auto https://host/play/movie.mp4 extra=1"))
        #expect(url.absoluteString == "https://host/play/movie.mp4")
    }

    @Test func `resolvedURL passes through a bare URL`() throws {
        let url = try #require(StalkerLink.resolvedURL(from: "https://host/play/movie.mp4"))
        #expect(url.absoluteString == "https://host/play/movie.mp4")
    }
}

struct StalkerDTODecodingTests {
    private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func `handshake envelope decodes the token`() throws {
        let json = #"{"js":{"token":"abc123","random":"x"}}"#
        let env = try decode(StalkerEnvelope<StalkerHandshake>.self, json)
        #expect(env.js.token == "abc123")
    }

    @Test func `channel decodes string and numeric ids alike`() throws {
        let json = """
        {"js":{"data":[
          {"id":"5","name":"News","number":"5","cmd":"ffmpeg http://h/5","logo":"a.png","tv_genre_id":"2","xmltv_id":"news.x"},
          {"id":7,"name":"Sport","number":7,"cmd":"http://h/7","tv_genre_id":3}
        ]}}
        """
        let env = try decode(StalkerEnvelope<StalkerPage<StalkerChannel>>.self, json)
        #expect(env.js.data.count == 2)
        #expect(env.js.data[0].id == "5")
        #expect(env.js.data[0].number == 5)
        #expect(env.js.data[0].genreId == "2")
        #expect(env.js.data[1].id == "7")
        #expect(env.js.data[1].number == 7)
    }

    @Test func `paginated VOD list reads totals from string fields`() throws {
        let json = """
        {"js":{"total_items":"40","max_page_items":"14","data":[
          {"id":"100","name":"A Movie","cmd":"/media/100.mpg","screenshot_uri":"a.jpg","year":"2021",
           "added":"2026-07-10 12:00:00","category_id":"9"}
        ]}}
        """
        let env = try decode(StalkerEnvelope<StalkerPage<StalkerVODItem>>.self, json)
        #expect(env.js.totalItems == 40)
        #expect(env.js.maxPageItems == 14)
        #expect(env.js.data.first?.name == "A Movie")
        #expect(env.js.data.first?.cmd == "/media/100.mpg")
        // `added` (Recently Added ordering) and `category_id` (single-pass `*`
        // walk category assignment) must decode.
        #expect(env.js.data.first?.added == "2026-07-10 12:00:00")
        #expect(env.js.data.first?.categoryId == "9")
    }

    @Test func `create_link decodes the resolved cmd`() throws {
        let json = #"{"js":{"cmd":"ffmpeg http://host/live/1.ts","id":"1"}}"#
        let env = try decode(StalkerEnvelope<StalkerCreateLink>.self, json)
        #expect(env.js.cmd == "ffmpeg http://host/live/1.ts")
    }

    @Test func `categories decode as a bare array`() throws {
        let json = #"{"js":[{"id":"1","title":"Movies"},{"id":"2","title":"Kids"}]}"#
        let env = try decode(StalkerEnvelope<[StalkerCategory]>.self, json)
        #expect(env.js.count == 2)
        #expect(env.js[1].title == "Kids")
    }
}

struct StalkerPlayableMediaTests {
    @Test func `a Stalker live stream becomes a deferred placeholder`() throws {
        let playlist = Playlist(
            name: "Portal",
            portalURL: "http://host/c/",
            macAddress: "00:1A:79:3F:A2:0B"
        )
        let stream = LiveStream(id: "uuid-live-5", streamId: 5, name: "News")
        stream.directURL = "ffmpeg http://host/ch/5"

        let media = try #require(PlayableMedia.from(stream: stream, playlist: playlist))
        #expect(StalkerLink.isPlaceholder(media.url))
        let decoded = try #require(StalkerLink.decode(media.url))
        #expect(decoded.type == .itv)
        #expect(decoded.cmd == "ffmpeg http://host/ch/5")
    }

    @Test func `a Stalker movie becomes a VOD placeholder`() throws {
        let playlist = Playlist(
            name: "Portal",
            portalURL: "http://host/c/",
            macAddress: "00:1A:79:3F:A2:0B"
        )
        let movie = Movie(id: "uuid-movie-9", streamId: 9, name: "A Movie")
        movie.directURL = "/media/9.mpg"

        let media = try #require(PlayableMedia.from(movie: movie, playlist: playlist))
        let decoded = try #require(StalkerLink.decode(media.url))
        #expect(decoded.type == .vod)
        #expect(decoded.cmd == "/media/9.mpg")
    }
}
