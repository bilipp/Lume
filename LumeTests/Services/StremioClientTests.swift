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

    @Test func `stream support respects the resource's type and id-prefix scoping`() throws {
        // AIOStreams-style: an object stream resource scoped to types + prefixes.
        let scoped: StremioManifest = try decode("""
        {
            "id": "com.example.aio", "name": "AIO", "types": ["movie", "series", "anime"],
            "resources": [
                { "name": "catalog", "types": ["movie", "series"], "idPrefixes": ["tt"] },
                { "name": "stream", "types": ["movie", "series"], "idPrefixes": ["tt", "kitsu"] }
            ]
        }
        """)
        #expect(scoped.supportsStreams(forType: "movie", idPrefix: "tt"))
        #expect(scoped.supportsStreams(forType: "series", idPrefix: "kitsu"))
        #expect(!scoped.supportsStreams(forType: "tv", idPrefix: "tt"))
        #expect(!scoped.supportsStreams(forType: "movie", idPrefix: "yt"))
    }

    @Test func `bare stream resource falls back to manifest-level scoping`() throws {
        let bare: StremioManifest = try decode("""
        {
            "id": "com.example.bare", "name": "Bare", "types": ["movie"],
            "resources": ["stream"], "idPrefixes": ["tt"]
        }
        """)
        #expect(bare.supportsStreams(forType: "movie", idPrefix: "tt"))
        #expect(!bare.supportsStreams(forType: "series", idPrefix: "tt"))

        // No scoping anywhere: the addon is taken at its word.
        let open: StremioManifest = try decode("""
        { "id": "com.example.open", "name": "Open", "resources": ["stream"] }
        """)
        #expect(open.supportsStreams(forType: "movie", idPrefix: "tt"))
    }

    @Test func `catalog-only addons declare no stream support`() throws {
        // Cinemeta-style: catalog + meta only.
        let cinemeta: StremioManifest = try decode("""
        {
            "id": "com.linvo.cinemeta", "name": "Cinemeta", "types": ["movie", "series"],
            "resources": ["catalog", "meta", "addon_catalog"]
        }
        """)
        #expect(!cinemeta.supportsStreams(forType: "movie", idPrefix: "tt"))
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
    }

    @Test func `stream decodes behaviorHints`() throws {
        let stream: StremioStream = try decode("""
        {
            "url": "https://cdn.example.com/movie.mkv",
            "name": "[TB] TorBox 2160p",
            "description": "BluRay REMUX | 62.3 GB",
            "behaviorHints": {
                "bingeGroup": "addon|2160p|REMUX",
                "filename": "Movie.2160p.mkv",
                "videoSize": 62254402955,
                "notWebReady": true
            }
        }
        """)
        #expect(stream.behaviorHints?.bingeGroup == "addon|2160p|REMUX")
        #expect(stream.behaviorHints?.filename == "Movie.2160p.mkv")
        #expect(stream.behaviorHints?.videoSize == 62_254_402_955)
        #expect(stream.behaviorHints?.notWebReady == true)
    }

    @Test func `behaviorHints tolerate a string videoSize and junk fields`() throws {
        let stream: StremioStream = try decode("""
        {
            "url": "https://cdn.example.com/movie.mkv",
            "behaviorHints": { "videoSize": "12345", "bingeGroup": 7 }
        }
        """)
        #expect(stream.behaviorHints?.videoSize == 12345)
        #expect(stream.behaviorHints?.bingeGroup == nil)
    }

    @Test func `subtitles decode`() throws {
        let response: StremioSubtitlesResponse = try decode("""
        { "subtitles": [{ "id": "s1", "url": "https://subs.example/en.srt", "lang": "eng" }] }
        """)
        #expect(response.subtitles.first?.lang == "eng")
    }
}

// MARK: - Catalog paging

struct StremioCatalogWalkerTests {
    /// Builds metas `first..<first+count` with ids "id<N>".
    private func metas(from first: Int, count: Int) throws -> [StremioMeta] {
        let json = (first ..< first + count)
            .map { #"{ "id": "id\#($0)", "type": "movie", "name": "M\#($0)" }"# }
            .joined(separator: ",")
        return try JSONDecoder().decode([StremioMeta].self, from: Data("[\(json)]".utf8))
    }

    @Test func `keeps paging past a page shorter than 100`() async throws {
        // AIOStreams serves 99-item pages; a fixed-page-size heuristic would
        // stop after one.
        let pages = try [metas(from: 0, count: 99), metas(from: 99, count: 99), metas(from: 198, count: 40)]
        var requestedSkips: [Int] = []
        let items = await ContentSyncManager.walkStremioCatalog(maxItems: 500) { skip in
            requestedSkips.append(skip)
            let index = requestedSkips.count - 1
            return index < pages.count ? pages[index] : []
        }
        #expect(items.count == 238)
        #expect(requestedSkips == [0, 99, 198, 238])
    }

    @Test func `stops after one extra request when the addon ignores skip`() async throws {
        let page = try metas(from: 0, count: 99)
        var requests = 0
        let items = await ContentSyncManager.walkStremioCatalog(maxItems: 500) { _ in
            requests += 1
            return page
        }
        #expect(items.count == 99)
        #expect(requests == 2)
    }

    @Test func `caps at maxItems`() async throws {
        let all = try metas(from: 0, count: 300)
        let items = await ContentSyncManager.walkStremioCatalog(maxItems: 150) { skip in
            Array(all.dropFirst(skip).prefix(100))
        }
        #expect(items.count == 150)
    }

    @Test func `treats a failing page as the end of the catalog`() async throws {
        let first = try metas(from: 0, count: 100)
        let items = await ContentSyncManager.walkStremioCatalog(maxItems: 500) { skip in
            skip == 0 ? first : nil
        }
        #expect(items.count == 100)
    }
}

// MARK: - Stream auto-pick

struct StremioAutoPickTests {
    private func options(bingeGroups: [String?]) throws -> [StremioStreamOption] {
        try bingeGroups.enumerated().map { index, group in
            let hints = group.map { #", "behaviorHints": { "bingeGroup": "\#($0)" }"# } ?? ""
            let stream = try JSONDecoder().decode(
                StremioStream.self,
                from: Data(#"{ "url": "https://cdn.example.com/\#(index).mkv", "name": "S\#(index)" \#(hints) }"#.utf8)
            )
            let url = try #require(stream.playableURL)
            return StremioStreamOption(id: index, url: url, stream: stream)
        }
    }

    @Test func `a lone stream plays without asking`() throws {
        let lone = try options(bingeGroups: [nil])
        #expect(StremioStreamResolver.autoPick(from: lone, matching: nil, askEnabled: true) == lone.first)
    }

    @Test func `disabled picker takes the addon's first stream`() throws {
        let many = try options(bingeGroups: ["a", "b"])
        #expect(StremioStreamResolver.autoPick(from: many, matching: nil, askEnabled: false) == many.first)
    }

    @Test func `binge group continuation skips the picker`() throws {
        let many = try options(bingeGroups: ["a", "b", "b"])
        let pick = StremioStreamResolver.autoPick(from: many, matching: "b", askEnabled: true)
        #expect(pick?.id == 1)
    }

    @Test func `several streams without a match ask the viewer`() throws {
        let many = try options(bingeGroups: ["a", "b"])
        #expect(StremioStreamResolver.autoPick(from: many, matching: "c", askEnabled: true) == nil)
        #expect(StremioStreamResolver.autoPick(from: many, matching: nil, askEnabled: true) == nil)
    }
}

// MARK: - Proxy headers

struct StremioProxyHeaderTests {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func `stream decodes proxyHeaders request headers`() throws {
        let stream: StremioStream = try decode("""
        {
            "url": "https://proxy.example.com/movie.mkv",
            "behaviorHints": {
                "notWebReady": true,
                "proxyHeaders": {
                    "request": { "User-Agent": "Lume", "Authorization": "Bearer token" },
                    "response": { "Content-Type": "video/mp4" }
                }
            }
        }
        """)
        #expect(stream.requestHeaders == ["User-Agent": "Lume", "Authorization": "Bearer token"])
    }

    @Test func `missing or empty proxyHeaders collapse to nil`() throws {
        let plain: StremioStream = try decode(#"{ "url": "https://cdn.example.com/movie.mkv" }"#)
        #expect(plain.requestHeaders == nil)

        let empty: StremioStream = try decode("""
        { "url": "https://cdn.example.com/movie.mkv", "behaviorHints": { "proxyHeaders": { "request": {} } } }
        """)
        #expect(empty.requestHeaders == nil)
    }

    @Test func `junk proxyHeaders don't fail the stream`() throws {
        let junk: StremioStream = try decode("""
        { "url": "https://cdn.example.com/movie.mkv", "behaviorHints": { "proxyHeaders": "nope" } }
        """)
        #expect(junk.requestHeaders == nil)
        #expect(junk.playableURL != nil)
    }
}

// MARK: - Resource support scoping

struct StremioResourceSupportTests {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func `subtitle support respects resource scoping`() throws {
        let manifest: StremioManifest = try decode("""
        {
            "id": "org.stremio.opensubtitlesv3", "name": "OpenSubtitles v3",
            "types": ["movie", "series"],
            "resources": ["subtitles"], "idPrefixes": ["tt"]
        }
        """)
        #expect(manifest.supports(resource: "subtitles", type: "movie", idPrefix: "tt"))
        #expect(manifest.supports(resource: "subtitles", type: "series", idPrefix: "tt"))
        #expect(!manifest.supports(resource: "subtitles", type: "movie", idPrefix: "kitsu"))
        #expect(!manifest.supports(resource: "stream", type: "movie", idPrefix: "tt"))
    }

    @Test func `id prefixes derive from the meta id`() {
        #expect(StremioStreamResolver.idPrefix(of: "tt0898266") == "tt")
        #expect(StremioStreamResolver.idPrefix(of: "tt0898266:9:17") == "tt")
        #expect(StremioStreamResolver.idPrefix(of: "kitsu:7442") == "kitsu")
        #expect(StremioStreamResolver.idPrefix(of: "kitsu:7442:1") == "kitsu")
    }
}

// MARK: - Mixed-type catalog bucketing

struct StremioBucketTests {
    @Test func `items route to the bucket their own type names`() {
        #expect(ContentSyncManager.StremioBucket(metaType: "movie") == .movie)
        #expect(ContentSyncManager.StremioBucket(metaType: "series") == .series)
        #expect(ContentSyncManager.StremioBucket(metaType: "tv") == .live)
        #expect(ContentSyncManager.StremioBucket(metaType: "channel") == .live)
    }

    @Test func `unknown item types default to the movie bucket`() {
        // Such items play straight off their meta id; the series path would
        // demand an episode list they may not have.
        #expect(ContentSyncManager.StremioBucket(metaType: "events") == .movie)
        #expect(ContentSyncManager.StremioBucket(metaType: "") == .movie)
    }
}

// MARK: - Subtitle merging

struct StremioSubtitleMergeTests {
    private func subtitle(_ id: String, url: String, lang: String) -> StremioSubtitle {
        StremioSubtitle(id: id, url: url, lang: lang)
    }

    @Test func `merges sources in order and dedupes by URL`() {
        let merged = StremioSubtitleResolver.merge([
            [subtitle("a1", url: "https://subs.example/en-1.srt", lang: "eng")],
            [
                subtitle("b1", url: "https://subs.example/en-1.srt", lang: "eng"),
                subtitle("b2", url: "https://subs.example/de-1.srt", lang: "ger")
            ]
        ])
        #expect(merged.map(\.url.absoluteString) == [
            "https://subs.example/en-1.srt",
            "https://subs.example/de-1.srt"
        ])
        #expect(merged.first?.language == "eng")
    }

    @Test func `caps tracks per language`() {
        let flood = (0 ..< 10).map { subtitle("s\($0)", url: "https://subs.example/en-\($0).srt", lang: "eng") }
        let merged = StremioSubtitleResolver.merge([flood])
        #expect(merged.count == StremioSubtitleResolver.maxTracksPerLanguage)
    }

    @Test func `skips non-http and malformed URLs`() {
        let merged = StremioSubtitleResolver.merge([[
            subtitle("f", url: "ftp://subs.example/en.srt", lang: "eng"),
            subtitle("ok", url: "https://subs.example/en.srt", lang: "eng")
        ]])
        #expect(merged.count == 1)
        #expect(merged.first?.url.absoluteString == "https://subs.example/en.srt")
    }
}
