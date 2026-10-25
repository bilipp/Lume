import Foundation
@testable import Lume
import Testing

// MARK: - Payload shapes

struct MDBListSyncItemsTests {
    @Test func `movie payload encodes the mdblist sync shape`() throws {
        let data = try JSONEncoder().encode(MDBListSyncItems.movie(tmdbID: 272, title: "Batman Begins"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let movies = try #require(json["movies"] as? [[String: Any]])
        #expect(movies.count == 1)
        #expect(movies[0]["title"] as? String == "Batman Begins")
        let ids = try #require(movies[0]["ids"] as? [String: Any])
        #expect(ids["tmdb"] as? Int == 272)
        #expect(json["shows"] == nil)
    }

    @Test func `episode payload nests the episode under its season`() throws {
        // A season without an `episodes` array would cascade to every episode
        // in it, so the episode must always be nested.
        let data = try JSONEncoder().encode(
            MDBListSyncItems.episode(showTMDBID: 1396, showTitle: "Breaking Bad", season: 2, episode: 3)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let shows = try #require(json["shows"] as? [[String: Any]])
        let ids = try #require(shows[0]["ids"] as? [String: Any])
        let seasons = try #require(shows[0]["seasons"] as? [[String: Any]])
        let episodes = try #require(seasons[0]["episodes"] as? [[String: Any]])
        #expect(ids["tmdb"] as? Int == 1396)
        #expect(seasons[0]["number"] as? Int == 2)
        #expect(episodes[0]["number"] as? Int == 3)
        #expect(json["movies"] == nil)
    }

    @Test func `ids decode integer and string tmdb forms`() throws {
        let intForm = try JSONDecoder().decode(MDBListIDs.self, from: Data(#"{"tmdb": 272, "mdblist": "a388"}"#.utf8))
        let stringForm = try JSONDecoder().decode(MDBListIDs.self, from: Data(#"{"tmdb": "272"}"#.utf8))
        let missing = try JSONDecoder().decode(MDBListIDs.self, from: Data(#"{"imdb": "tt0372784"}"#.utf8))
        #expect(intForm.tmdb == 272)
        #expect(stringForm.tmdb == 272)
        #expect(missing.tmdb == nil)
    }

    @Test func `form body percent-encodes values in a stable order`() throws {
        let body = MDBListSyncClient.formBody([
            "scope": "read write",
            "client_id": "abc",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
        let string = try #require(String(data: body, encoding: .utf8))
        #expect(string == "client_id=abc&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&scope=read%20write")
    }
}

// MARK: - Decoding

struct MDBListSyncDecodingTests {
    @Test func `device code falls back to mdblist's defaults`() throws {
        let code = try JSONDecoder().decode(
            MDBListDeviceCode.self,
            from: Data(#"{"device_code": "dev", "user_code": "ABCD-1234"}"#.utf8)
        )
        #expect(code.verificationURL == "https://mdblist.com/oauth/device/")
        #expect(code.verificationURLComplete == nil)
        #expect(code.expiresIn == 300)
        #expect(code.interval == 5)
        #expect(MDBListSyncClient.displayURL(for: code) == "mdblist.com/oauth/device")
        #expect(MDBListSyncClient.activationURL(for: code)?.absoluteString == "https://mdblist.com/oauth/device/")
    }

    @Test func `activation url prefers the pre-filled variant`() {
        let code = MDBListDeviceCode(
            deviceCode: "d", userCode: "ABCD-1234",
            verificationURL: "https://mdblist.com/oauth/device/",
            verificationURLComplete: "https://mdblist.com/oauth/device/?user_code=ABCD-1234",
            expiresIn: 300, interval: 5
        )
        #expect(
            MDBListSyncClient.activationURL(for: code)?.absoluteString
                == "https://mdblist.com/oauth/device/?user_code=ABCD-1234"
        )
    }

    @Test func `a refresh without a new refresh token keeps the old one`() throws {
        let response = try JSONDecoder().decode(
            MDBListTokenResponse.self,
            from: Data(#"{"access_token": "new", "expires_in": 2592000}"#.utf8)
        )
        let tokens = response.tokens(previousRefreshToken: "old-refresh")
        #expect(tokens.accessToken == "new")
        #expect(tokens.refreshToken == "old-refresh")
        #expect(tokens.expiresIn == 2_592_000)
        #expect(tokens.needsRefresh == false)
    }

    @Test func `a token within a day of expiry needs refreshing`() {
        let issued = Date().addingTimeInterval(-29.5 * 24 * 3600).timeIntervalSince1970
        let tokens = MDBListTokens(accessToken: "a", refreshToken: "r", issuedAt: issued, expiresIn: 2_592_000)
        #expect(tokens.needsRefresh == true)
    }

    @Test func `user display name prefers the username`() throws {
        let user = try JSONDecoder().decode(MDBListUser.self, from: Data(#"{"username": "linas", "name": "Linas"}"#.utf8))
        let nameOnly = try JSONDecoder().decode(MDBListUser.self, from: Data(#"{"username": "", "name": "Linas"}"#.utf8))
        #expect(user.displayName == "linas")
        #expect(nameOnly.displayName == "Linas")
    }

    @Test func `watchlist rows keep their kind tmdb id and added date`() throws {
        let json = """
        {
            "movies": [
                {"id": 661539, "title": "A Complete Unknown", "mediatype": "movie", "watchlist_at": "2025-02-02 17:28:22.000000"},
                {"id": null, "title": "No TMDB", "mediatype": "movie"}
            ],
            "shows": [
                {"id": 222766, "mediatype": "show", "watchlist_at": "2025-02-21 13:00:05.108530"}
            ],
            "pagination": {"page": 1, "limit": 10, "has_more": false}
        }
        """
        let page = try JSONDecoder().decode(MDBListWatchlistPage.self, from: Data(json.utf8))

        #expect(page.entries.map(\.tmdbID) == [661_539, 222_766])
        #expect(page.entries.map(\.kind) == [.movie, .show])
        let added = try #require(page.entries[0].addedAt)
        #expect(added == ISO8601DateFormatter().date(from: "2025-02-02T17:28:22Z"))
        #expect(page.pagination?.hasMore == false)
    }

    @Test func `dates parse every form mdblist sends`() {
        let expected = ISO8601DateFormatter().date(from: "2025-10-21T12:00:00Z")
        #expect(MDBListDates.parse("2025-10-21T12:00:00Z") == expected)
        #expect(MDBListDates.parse("2025-10-21T12:00:00.000Z") == expected)
        #expect(MDBListDates.parse("2025-10-21 12:00:00.000000") == expected)
        #expect(MDBListDates.parse("2025-10-21 12:00:00") == expected)
        #expect(MDBListDates.parse(nil) == nil)
        #expect(MDBListDates.parse("not a date") == nil)
    }

    @Test func `watchlist sorts newest first with undated entries last`() {
        let older = MDBListWatchlistEntry(kind: .movie, tmdbID: 1, addedAt: Date(timeIntervalSince1970: 100))
        let newer = MDBListWatchlistEntry(kind: .show, tmdbID: 2, addedAt: Date(timeIntervalSince1970: 200))
        let undated = MDBListWatchlistEntry(kind: .movie, tmdbID: 3, addedAt: nil)
        let sorted = MDBListService.newestFirst([undated, older, newer])
        #expect(sorted.map(\.tmdbID) == [2, 1, 3])
    }
}

// MARK: - Client

struct MDBListSyncClientConfigTests {
    @Test func `is configured requires a client id`() {
        #expect(MDBListSyncClient(clientID: nil).isConfigured == false)
        #expect(MDBListSyncClient(clientID: "").isConfigured == false)
        #expect(MDBListSyncClient(clientID: "$(MDBLIST_CLIENT_ID)").isConfigured == false)
        #expect(MDBListSyncClient(clientID: "id").isConfigured == true)
    }

    @Test func `requests fail fast without a client id`() async {
        await #expect(throws: MDBListSyncError.notConfigured) {
            _ = try await MDBListSyncClient(clientID: nil).requestDeviceCode()
        }
    }
}

/// Each test stubs its own host, so routes never collide across tests.
struct MDBListSyncClientTests {
    private func makeClient(host: String) -> MDBListSyncClient {
        MDBListSyncClient(session: StubURLProtocol.makeSession(), clientID: "lume", baseURL: "https://\(host)")
    }

    @Test func `device code decodes the rfc 8628 response`() async throws {
        StubURLProtocol.register(
            host: "device.mdblist.test",
            pathSuffix: "/oauth/device-authorization/",
            response: StubURLProtocol.Response(body: """
            {
                "device_code": "DEVICECODE123",
                "user_code": "WDJB-MJHT",
                "verification_uri": "https://mdblist.com/oauth/device/",
                "expires_in": 600,
                "interval": 5
            }
            """)
        )

        let code = try await makeClient(host: "device.mdblist.test").requestDeviceCode()

        #expect(code.deviceCode == "DEVICECODE123")
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.expiresIn == 600)
    }

    @Test func `an unknown client id reads as rejected credentials`() async {
        // MDBList's live answer for a client id it doesn't know.
        StubURLProtocol.register(
            host: "unknown-client.mdblist.test",
            pathSuffix: "/oauth/device-authorization/",
            response: StubURLProtocol.Response(
                status: 400,
                body: #"{"error": "invalid_request", "error_description": "Invalid client_id parameter value."}"#
            )
        )

        await #expect(throws: MDBListSyncError.invalidClient) {
            _ = try await makeClient(host: "unknown-client.mdblist.test").requestDeviceCode()
        }
    }

    @Test(arguments: [
        ("authorization_pending", MDBListSyncError.authorizationPending),
        ("slow_down", .slowDown),
        ("expired_token", .codeExpired),
        ("access_denied", .accessDenied),
        ("invalid_client", .invalidClient),
        ("invalid_grant", .server(400))
    ])
    func `poll errors map to typed outcomes`(code: String, expected: MDBListSyncError) async {
        let host = "poll-\(code.replacingOccurrences(of: "_", with: "-")).mdblist.test"
        StubURLProtocol.register(
            host: host,
            pathSuffix: "/oauth/token/",
            response: StubURLProtocol.Response(status: 400, body: #"{"error": "\#(code)"}"#)
        )

        await #expect(throws: expected) {
            _ = try await makeClient(host: host).pollForToken(deviceCode: "d")
        }
    }

    @Test func `an approved poll returns the token set`() async throws {
        StubURLProtocol.register(
            host: "approved.mdblist.test",
            pathSuffix: "/oauth/token/",
            response: StubURLProtocol.Response(body: """
            {"access_token": "abc", "token_type": "Bearer", "expires_in": 2592000, "refresh_token": "def", "scope": "read write"}
            """)
        )

        let response = try await makeClient(host: "approved.mdblist.test").pollForToken(deviceCode: "d")

        #expect(response.accessToken == "abc")
        #expect(response.refreshToken == "def")
        #expect(response.scope == "read write")
    }

    @Test func `an expired token reads as not authenticated`() async {
        StubURLProtocol.register(
            host: "unauthorized.mdblist.test",
            pathSuffix: "/user",
            response: StubURLProtocol.Response(status: 401, body: #"{"error": "Invalid API key"}"#)
        )

        await #expect(throws: MDBListSyncError.notAuthenticated) {
            _ = try await makeClient(host: "unauthorized.mdblist.test").currentUser(accessToken: "stale")
        }
    }

    @Test func `watched history follows the next cursor`() async throws {
        let host = "cursor.mdblist.test"
        StubURLProtocol.register(host: host, query: ("offset", "0"), response: StubURLProtocol.Response(body: """
        {
            "movies": [{"last_watched_at": "2025-10-21T12:00:00Z", "movie": {"title": "Batman Begins", "ids": {"tmdb": 272}}}],
            "episodes": [],
            "pagination": {"has_more": true, "next_cursor": "page2"}
        }
        """))
        StubURLProtocol.register(host: host, query: ("cursor", "page2"), response: StubURLProtocol.Response(body: """
        {
            "episodes": [{
                "last_watched_at": "2025-10-15T20:00:00Z",
                "episode": {"season": 1, "number": 1, "name": "Pilot", "show": {"title": "Breaking Bad", "ids": {"tmdb": 1396}}}
            }],
            "pagination": {"has_more": false}
        }
        """))

        let history = try await makeClient(host: host).watchedHistory(accessToken: "t")

        #expect(history.movies.map(\.movie.ids.tmdb) == [272])
        #expect(history.episodes.count == 1)
        #expect(history.episodes[0].episode.show.ids.tmdb == 1396)
        #expect(history.episodes[0].episode.season == 1)
        #expect(history.episodes[0].episode.number == 1)
    }

    @Test func `watchlist pages by offset when there is no cursor`() async throws {
        let host = "offset.mdblist.test"
        StubURLProtocol.register(host: host, query: ("offset", "0"), response: StubURLProtocol.Response(body: """
        {"movies": [{"id": 1, "watchlist_at": "2025-02-02 17:28:22.000000"}], "shows": [], "pagination": {"has_more": true}}
        """))
        StubURLProtocol.register(host: host, query: ("offset", "1000"), response: StubURLProtocol.Response(body: """
        {"movies": [], "shows": [{"id": 2}], "pagination": {"has_more": false}}
        """))

        let entries = try await makeClient(host: host).watchlist(accessToken: "t")

        #expect(entries.map(\.tmdbID) == [1, 2])
    }
}
