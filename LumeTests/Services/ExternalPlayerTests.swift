import Foundation
@testable import Lume
import Testing

/// Serialized: the preference tests read and write shared `UserDefaults`
/// keys, which parallel execution interleaves.
@Suite(.serialized)
struct ExternalPlayerTests {
    @Test func `player all cases`() {
        #expect(ExternalPlayer.allCases.count == 3)
        #expect(ExternalPlayer.infuse.rawValue == "infuse")
        #expect(ExternalPlayer.vlc.rawValue == "vlc")
        #expect(ExternalPlayer.vidhub.rawValue == "vidhub")
    }

    @Test func `player schemes match registered apps`() {
        #expect(ExternalPlayer.infuse.scheme == "infuse")
        #expect(ExternalPlayer.vlc.scheme == "vlc-x-callback")
        #expect(ExternalPlayer.vidhub.scheme == "open-vidhub")
    }

    /// Every scheme must be declared in `LSApplicationQueriesSchemes` or
    /// `canOpenURL(_:)` answers `false` and the hand-off silently never happens.
    @Test func `every player scheme is declared in Info plist`() throws {
        let declared = try #require(
            Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String]
        )
        for player in ExternalPlayer.allCases {
            #expect(declared.contains(player.scheme), "\(player.scheme) missing from LSApplicationQueriesSchemes")
        }
    }

    @Test func `infuse deep link wraps stream URL`() throws {
        let stream = try #require(URL(string: "http://example.com/movie.mkv"))
        let link = try #require(ExternalPlayer.infuse.deepLink(for: stream))
        #expect(link.scheme == "infuse")
        #expect(link.absoluteString == "infuse://x-callback-url/play?url=http%3A%2F%2Fexample.com%2Fmovie.mkv")
    }

    @Test func `vlc deep link uses stream action`() throws {
        let stream = try #require(URL(string: "http://example.com/movie.mkv"))
        let link = try #require(ExternalPlayer.vlc.deepLink(for: stream))
        #expect(link.scheme == "vlc-x-callback")
        #expect(link.absoluteString.hasPrefix("vlc-x-callback://x-callback-url/stream?url="))
    }

    /// `/open`, not the `/play` the docs steer new integrations to: the
    /// shipping App Store build answers only the former and silently ignores
    /// the latter.
    @Test func `vidhub deep link uses the open action`() throws {
        let stream = try #require(URL(string: "http://example.com/movie.mkv"))
        let link = try #require(ExternalPlayer.vidhub.deepLink(for: stream))
        #expect(link.scheme == "open-vidhub")
        #expect(link.absoluteString == "open-vidhub://x-callback-url/open?url=http%3A%2F%2Fexample.com%2Fmovie.mkv")
    }

    @Test func `vidhub deep link percent-encodes a live stream query`() throws {
        let original = "http://host:8080/live/user/pass/1.m3u8?token=a&b=c"
        let stream = try #require(URL(string: original))
        let link = try #require(ExternalPlayer.vidhub.deepLink(for: stream))
        let encoded = try #require(link.absoluteString.components(separatedBy: "url=").last)
        #expect(!encoded.contains("&"))
        #expect(!encoded.contains("?"))
        #expect(encoded.removingPercentEncoding == original)
    }

    @Test func `deep link percent-encodes nested query so the stream URL survives`() throws {
        let stream = try #require(URL(string: "http://host:8080/live?user=abc&pass=def"))
        let link = try #require(ExternalPlayer.infuse.deepLink(for: stream))
        let query = try #require(link.absoluteString.components(separatedBy: "url=").last)
        #expect(!query.contains("&"))
        #expect(!query.contains("="))
        #expect(!query.contains("?"))
        #expect(query.contains("%3F"))
        #expect(query.contains("%26"))
        #expect(query.contains("%3D"))
    }

    @Test func `deep link round-trips through percent-decoding`() throws {
        let original = "http://host:8080/live?user=abc&pass=def"
        let stream = try #require(URL(string: original))
        let link = try #require(ExternalPlayer.infuse.deepLink(for: stream))
        let encoded = try #require(link.absoluteString.components(separatedBy: "url=").last)
        #expect(encoded.removingPercentEncoding == original)
    }

    @Test func `preference defaults to off and ignores unknown values`() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: PlayerSettings.externalPlayerKey)
        defer {
            if let saved {
                defaults.set(saved, forKey: PlayerSettings.externalPlayerKey)
            } else {
                defaults.removeObject(forKey: PlayerSettings.externalPlayerKey)
            }
        }

        defaults.removeObject(forKey: PlayerSettings.externalPlayerKey)
        #expect(ExternalPlayback.preferred == nil)

        defaults.set("", forKey: PlayerSettings.externalPlayerKey)
        #expect(ExternalPlayback.preferred == nil)

        defaults.set("notAPlayer", forKey: PlayerSettings.externalPlayerKey)
        #expect(ExternalPlayback.preferred == nil)

        defaults.set("infuse", forKey: PlayerSettings.externalPlayerKey)
        #expect(ExternalPlayback.preferred == .infuse)

        defaults.set("vlc", forKey: PlayerSettings.externalPlayerKey)
        #expect(ExternalPlayback.preferred == .vlc)

        defaults.set("vidhub", forKey: PlayerSettings.externalPlayerKey)
        #expect(ExternalPlayback.preferred == .vidhub)
    }

    // MARK: - Scope

    @Test func `scope includes the matching kinds`() {
        #expect(ExternalPlayerScope.all.includes(.vod))
        #expect(ExternalPlayerScope.all.includes(.live))
        #expect(ExternalPlayerScope.vod.includes(.vod))
        #expect(!ExternalPlayerScope.vod.includes(.live))
        #expect(ExternalPlayerScope.live.includes(.live))
        #expect(!ExternalPlayerScope.live.includes(.vod))
    }

    @Test func `scope defaults to movies and series and ignores unknown values`() {
        withStoredScope { defaults in
            defaults.removeObject(forKey: PlayerSettings.externalPlayerScopeKey)
            #expect(ExternalPlayback.scope == .vod)

            defaults.set("notAScope", forKey: PlayerSettings.externalPlayerScopeKey)
            #expect(ExternalPlayback.scope == .vod)

            defaults.set("all", forKey: PlayerSettings.externalPlayerScopeKey)
            #expect(ExternalPlayback.scope == .all)

            defaults.set("live", forKey: PlayerSettings.externalPlayerScopeKey)
            #expect(ExternalPlayback.scope == .live)
        }
    }

    @Test func `hand-off target honours the scope`() throws {
        let stream = try #require(URL(string: "http://example.com/stream.ts"))
        let vod = makeMedia(url: stream, kind: .vod)
        let live = makeMedia(url: stream, kind: .live)

        withStoredPlayer { playerDefaults in
            playerDefaults.set("infuse", forKey: PlayerSettings.externalPlayerKey)
            withStoredScope { defaults in
                defaults.set("vod", forKey: PlayerSettings.externalPlayerScopeKey)
                #expect(ExternalPlayback.target(for: vod) == .infuse)
                #expect(ExternalPlayback.target(for: live) == nil)

                defaults.set("live", forKey: PlayerSettings.externalPlayerScopeKey)
                #expect(ExternalPlayback.target(for: vod) == nil)
                #expect(ExternalPlayback.target(for: live) == .infuse)

                defaults.set("all", forKey: PlayerSettings.externalPlayerScopeKey)
                #expect(ExternalPlayback.target(for: vod) == .infuse)
                #expect(ExternalPlayback.target(for: live) == .infuse)
            }
        }
    }

    @Test func `local downloads never hand off regardless of scope`() {
        let download = makeMedia(url: URL(fileURLWithPath: "/tmp/movie.mkv"), kind: .vod)

        withStoredPlayer { playerDefaults in
            playerDefaults.set("infuse", forKey: PlayerSettings.externalPlayerKey)
            withStoredScope { defaults in
                defaults.set("all", forKey: PlayerSettings.externalPlayerScopeKey)
                #expect(ExternalPlayback.target(for: download) == nil)
            }
        }
    }

    private func makeMedia(url: URL, kind: PlayableMedia.Kind) -> PlayableMedia {
        PlayableMedia(
            id: kind == .live ? "channel-1" : "movie-1",
            url: url,
            title: kind == .live ? "Channel" : "Movie",
            subtitle: nil,
            posterURL: nil,
            kind: kind,
            startTime: 0,
            contentRef: kind == .live ? .live("1") : .movie("1")
        )
    }

    /// Runs `body` with the scope key restored afterwards — these tests write to
    /// `UserDefaults.standard`, which the app (and other suites) share.
    private func withStoredScope(_ body: (UserDefaults) -> Void) {
        restoring(PlayerSettings.externalPlayerScopeKey, body)
    }

    private func withStoredPlayer(_ body: (UserDefaults) -> Void) {
        restoring(PlayerSettings.externalPlayerKey, body)
    }

    private func restoring(_ key: String, _ body: (UserDefaults) -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)
        body(defaults)
    }
}
