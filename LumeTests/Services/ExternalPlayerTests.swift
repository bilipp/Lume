import Foundation
@testable import Lume
import Testing

struct ExternalPlayerTests {
    @Test func `player all cases`() {
        #expect(ExternalPlayer.allCases.count == 2)
        #expect(ExternalPlayer.infuse.rawValue == "infuse")
        #expect(ExternalPlayer.vlc.rawValue == "vlc")
    }

    @Test func `player schemes match registered apps`() {
        #expect(ExternalPlayer.infuse.scheme == "infuse")
        #expect(ExternalPlayer.vlc.scheme == "vlc-x-callback")
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
    }
}
