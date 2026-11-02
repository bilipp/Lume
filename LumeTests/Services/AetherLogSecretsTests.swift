#if !os(visionOS)
    import Foundation
    @testable import Lume
    import Testing

    struct AetherLogSecretsTests {
        private func secrets(_ string: String, headers: [String: String]? = nil) -> Set<String> {
            AetherLogSecrets.values(url: URL(string: string)!, httpHeaders: headers)
        }

        @Test func `the short xtream layout names its account`() {
            #expect(secrets("http://panel.example:8080/alice99/s3cretPw/12345") == ["alice99", "s3cretPw"])
            #expect(secrets("http://panel.example:8080/alice99/s3cretPw/12345.ts") == ["alice99", "s3cretPw"])
        }

        @Test func `route words are never taken for an account`() {
            #expect(secrets("http://cdn.example/hls/live/12345.m3u8").isEmpty)
            #expect(secrets("http://cdn.example/LIVE/s3cretPw/12345").subtracting(["s3cretPw"]).isEmpty)
        }

        @Test func `the long xtream layout names its account`() {
            // The engine scrubs the password here but logs the user name.
            #expect(secrets("http://panel.example/live/alice99/s3cretPw/12345.ts") == ["alice99", "s3cretPw"])
            #expect(secrets("http://panel.example/movie/alice99/s3cretPw/163084.mkv") == ["alice99", "s3cretPw"])
            #expect(secrets("http://panel.example/timeshift/alice99/s3cretPw/120/2026-11-02:20-15/12345.ts") == ["alice99", "s3cretPw"])
        }

        @Test func `other layouts are left to the engine`() {
            // Named parameters are the engine's own.
            #expect(secrets("http://panel.example/alice99/s3cretPw/channel-one").isEmpty)
            #expect(secrets("http://cdn.example/live/hls/stream/index.m3u8").isEmpty)
            #expect(secrets("http://panel.example/stream.m3u8?token=abcdef123").isEmpty)
        }

        @Test func `userinfo is registered`() {
            #expect(secrets("http://bob:hunter22@nas.example/movies/film.mkv") == ["hunter22"])
        }

        @Test func `header credentials are registered whole and alone`() {
            let basic = secrets("https://dav.example/film.mkv", headers: ["Authorization": "Basic Ym9iOmh1bnRlcjIy"])
            #expect(basic == ["Basic Ym9iOmh1bnRlcjIy", "Ym9iOmh1bnRlcjIy"])
            let plex = secrets("https://plex.example/video.mkv", headers: ["X-Plex-Token": "plexToken123"])
            #expect(plex.contains("plexToken123"))
        }

        @Test func `a jellyfin token inside its authorization header is registered`() {
            let value = #"MediaBrowser Client="Lume", Device="Apple TV", Token="jfTokenABC""#
            #expect(secrets("https://jf.example/Videos/1/stream", headers: ["Authorization": value]).contains("jfTokenABC"))
        }

        @Test func `values the engine would refuse are dropped`() {
            #expect(secrets("http://abc:xyz@host.example/film.mkv").isEmpty)
        }
    }
#endif
