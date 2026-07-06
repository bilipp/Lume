import Foundation
@testable import Lume
import Testing

// MARK: - Manifest URL handling

struct StremioManifestURLTests {
    @Test func `normalizes a stremio install link to https`() {
        let normalized = StremioManifestURL.normalized("stremio://v3-cinemeta.strem.io/manifest.json")
        #expect(normalized == "https://v3-cinemeta.strem.io/manifest.json")
    }

    @Test func `appends the manifest filename to a bare base URL`() {
        #expect(StremioManifestURL.normalized("https://addon.example.com") == "https://addon.example.com/manifest.json")
        #expect(StremioManifestURL.normalized("https://addon.example.com/") == "https://addon.example.com/manifest.json")
    }

    @Test func `keeps a full manifest URL untouched`() {
        let url = "https://addon.example.com/config123/manifest.json"
        #expect(StremioManifestURL.normalized(url) == url)
    }

    @Test func `trims whitespace`() {
        #expect(StremioManifestURL.normalized("  https://a.example/manifest.json \n") == "https://a.example/manifest.json")
    }

    @Test func `base URL strips the manifest filename but keeps config path segments`() {
        let base = StremioManifestURL.baseURL(of: "https://addon.example.com/config123/manifest.json")
        #expect(base?.absoluteString == "https://addon.example.com/config123")
    }
}

// MARK: - Resource URL construction

struct StremioResourceURLTests {
    private let base = URL(string: "https://addon.example.com")!

    @Test func `builds a plain catalog URL`() {
        let url = StremioClient.resourceURL(base: base, resource: "catalog", type: "movie", id: "top")
        #expect(url?.absoluteString == "https://addon.example.com/catalog/movie/top.json")
    }

    @Test func `encodes extras as a path segment before the json suffix`() {
        let url = StremioClient.resourceURL(
            base: base, resource: "catalog", type: "movie", id: "top",
            extras: [("skip", "100")]
        )
        #expect(url?.absoluteString == "https://addon.example.com/catalog/movie/top/skip=100.json")
    }

    @Test func `percent-encodes extra values`() {
        let url = StremioClient.resourceURL(
            base: base, resource: "catalog", type: "movie", id: "top",
            extras: [("search", "game of thrones"), ("skip", "100")]
        )
        #expect(url?.absoluteString == "https://addon.example.com/catalog/movie/top/search=game%20of%20thrones&skip=100.json")
    }

    @Test func `percent-encodes episode ids in stream URLs`() {
        let url = StremioClient.resourceURL(base: base, resource: "stream", type: "series", id: "tt0898266:9:17")
        #expect(url?.absoluteString == "https://addon.example.com/stream/series/tt0898266%3A9%3A17.json")
    }
}

// MARK: - Deferred play link

struct StremioLinkTests {
    @Test func `placeholder round-trips type and id`() throws {
        let url = try #require(StremioLink.placeholder(type: "series", id: "tt0898266:9:17"))
        #expect(StremioLink.isPlaceholder(url))
        let decoded = try #require(StremioLink.decode(url))
        #expect(decoded.type == "series")
        #expect(decoded.id == "tt0898266:9:17")
    }

    @Test func `regular URLs are not placeholders`() throws {
        let url = try #require(URL(string: "https://example.com/movie.mp4"))
        #expect(!StremioLink.isPlaceholder(url))
        #expect(StremioLink.decode(url) == nil)
    }
}

// MARK: - DTO decoding

struct StremioDTODecodingTests {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func `decodes a manifest with mixed string and object resources`() throws {
        let manifest: StremioManifest = try decode("""
        {
            "id": "com.example.addon",
            "version": "1.0.0",
            "name": "Example",
            "description": "An addon",
            "types": ["movie", "series"],
            "resources": [
                "catalog",
                { "name": "stream", "types": ["movie"], "idPrefixes": ["tt"] }
            ],
            "catalogs": [{ "type": "movie", "id": "top", "name": "Popular" }],
            "idPrefixes": ["tt"]
        }
        """)
        #expect(manifest.id == "com.example.addon")
        #expect(manifest.supportsResource("catalog"))
        #expect(manifest.supportsResource("stream"))
        #expect(!manifest.supportsResource("subtitles"))
        #expect(manifest.catalogs.count == 1)
        #expect(manifest.catalogs.first?.isBrowsable == true)
    }

    @Test func `manifest tolerates missing optional collections`() throws {
        let manifest: StremioManifest = try decode("""
        { "id": "com.example.addon", "name": "Example", "resources": ["meta"] }
        """)
        #expect(manifest.types.isEmpty)
        #expect(manifest.catalogs.isEmpty)
    }

    @Test func `catalog with a required extra is not browsable`() throws {
        let catalog: StremioCatalog = try decode("""
        {
            "type": "movie", "id": "search-only", "name": "Search",
            "extra": [{ "name": "search", "isRequired": true }]
        }
        """)
        #expect(!catalog.isBrowsable)
        #expect(catalog.requiredExtraNames == ["search"])
    }

    @Test func `catalog falls back to legacy extraRequired`() throws {
        let catalog: StremioCatalog = try decode("""
        {
            "type": "movie", "id": "year", "name": "New",
            "extraSupported": ["genre", "skip"],
            "extraRequired": ["genre"]
        }
        """)
        #expect(!catalog.isBrowsable)
        #expect(catalog.supportsSkip)
    }

    @Test func `meta decodes a numeric imdbRating and releaseInfo`() throws {
        let response: StremioMetaResponse = try decode("""
        {
            "meta": {
                "id": "tt1254207", "type": "movie", "name": "Big Buck Bunny",
                "imdbRating": 8.4, "releaseInfo": 2008,
                "genres": ["Animation", "Comedy"]
            }
        }
        """)
        #expect(response.meta.imdbRating == "8.4")
        #expect(response.meta.releaseInfo == "2008")
        #expect(response.meta.streamRequestId == "tt1254207")
    }

    @Test func `meta prefers behaviorHints defaultVideoId for stream requests`() throws {
        let meta: StremioMeta = try decode("""
        {
            "id": "tt1254207", "type": "movie", "name": "Big Buck Bunny",
            "behaviorHints": { "defaultVideoId": "tt1254207:1" }
        }
        """)
        #expect(meta.streamRequestId == "tt1254207:1")
    }

    @Test func `video decodes title-or-name and episode-or-number aliases`() throws {
        let cinemetaStyle: StremioVideo = try decode("""
        {
            "id": "tt0898266:9:17", "name": "The Explosion Implosion",
            "season": 9, "number": 17,
            "released": "2016-02-05T02:00:00.000Z",
            "thumbnail": "https://images.example/thumb.jpg",
            "overview": "Wolowitz and Koothrappali shoot a model rocket."
        }
        """)
        #expect(cinemetaStyle.title == "The Explosion Implosion")
        #expect(cinemetaStyle.season == 9)
        #expect(cinemetaStyle.episode == 17)

        let specStyle: StremioVideo = try decode("""
        { "id": "tt1:1:1", "title": "Pilot", "season": 1, "episode": 1, "released": "2010-01-01T00:00:00Z" }
        """)
        #expect(specStyle.title == "Pilot")
        #expect(specStyle.episode == 1)
    }

    @Test func `catalog response tolerates an empty payload`() throws {
        let empty: StremioCatalogResponse = try decode("{}")
        #expect(empty.metas.isEmpty)
    }

    @Test func `stream exposes a playable URL only for direct http sources`() throws {
        let response: StremioStreamResponse = try decode("""
        {
            "streams": [
                { "infoHash": "abcdef", "fileIdx": 0, "title": "Torrent 1080p" },
                { "ytId": "aqz-KE-bpKQ" },
                { "externalUrl": "https://example.com/watch" },
                { "url": "https://cdn.example.com/movie.mp4", "name": "HTTP 1080p" }
            ]
        }
        """)
        let playable = response.streams.compactMap(\.playableURL)
        #expect(playable.count == 1)
        #expect(playable.first?.absoluteString == "https://cdn.example.com/movie.mp4")
        #expect(StremioStreamResolver.bestStreamURL(from: response.streams)?.absoluteString == "https://cdn.example.com/movie.mp4")
    }

    @Test func `subtitles decode`() throws {
        let response: StremioSubtitlesResponse = try decode("""
        { "subtitles": [{ "id": "s1", "url": "https://subs.example/en.srt", "lang": "eng" }] }
        """)
        #expect(response.subtitles.first?.lang == "eng")
    }
}
