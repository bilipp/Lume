import Foundation
@testable import Lume
import Testing

// MARK: - Payload shapes

struct SimklSyncItemsTests {
    @Test func `movie payload encodes the simkl sync shape`() throws {
        let data = try JSONEncoder().encode(SimklSyncItems.movie(tmdbID: 296, title: "Terminator 3"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let movies = try #require(json["movies"] as? [[String: Any]])
        #expect(movies.count == 1)
        #expect(movies[0]["title"] as? String == "Terminator 3")
        let ids = try #require(movies[0]["ids"] as? [String: Any])
        #expect(ids["tmdb"] as? Int == 296)
        #expect(json["shows"] == nil)
    }

    @Test func `episode payload nests the season and episode`() throws {
        let data = try JSONEncoder().encode(
            SimklSyncItems.episode(showTMDBID: 1402, showTitle: "The Walking Dead", season: 1, episode: 4)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let shows = try #require(json["shows"] as? [[String: Any]])
        let seasons = try #require(shows[0]["seasons"] as? [[String: Any]])
        let episodes = try #require(seasons[0]["episodes"] as? [[String: Any]])
        #expect(seasons[0]["number"] as? Int == 1)
        #expect(episodes[0]["number"] as? Int == 4)
        #expect(json["movies"] == nil)
    }

    @Test func `ids decode integer and string tmdb forms`() throws {
        let intForm = """
        {"movie": {"ids": {"simkl": 55328, "tmdb": 1771}}, "status": "completed", "last_watched_at": null}
        """
        let stringForm = """
        {"movie": {"ids": {"simkl": 55328, "tmdb": "1771"}}, "status": "completed"}
        """
        let decodedInt = try JSONDecoder().decode(SimklWatchedMovie.self, from: Data(intForm.utf8))
        let decodedString = try JSONDecoder().decode(SimklWatchedMovie.self, from: Data(stringForm.utf8))
        #expect(decodedInt.movie.ids.tmdb == 1771)
        #expect(decodedString.movie.ids.tmdb == 1771)
    }
}

// MARK: - Client

struct SimklClientConfigTests {
    @Test func `is configured requires a client id`() {
        #expect(SimklClient(clientID: nil, clientSecret: nil).isConfigured == false)
        #expect(SimklClient(clientID: "$(SIMKL_CLIENT_ID)", clientSecret: nil).isConfigured == false)
        #expect(SimklClient(clientID: "", clientSecret: nil).isConfigured == false)
        #expect(SimklClient(clientID: "id", clientSecret: nil).isConfigured == true)
        #expect(SimklClient(clientID: "id", clientSecret: "secret").isConfigured == true)
    }

    @Test func `is configured tolerates an unsubstituted secret`() {
        // inject-env.sh only writes the secret key when one is set; the plist
        // placeholder never leaks in, but a stray one must not disable the
        // integration either.
        #expect(SimklClient(clientID: "id", clientSecret: "$(SIMKL_CLIENT_SECRET)").isConfigured == true)
    }
}

/// Serialized: the stub routes live in one static registry, and each test's
/// route is keyed by a client id unique to the test.
@Suite(.serialized)
struct SimklClientTests {
    private func makeClient(id: String) -> SimklClient {
        SimklClient(session: StubURLProtocol.makeSession(), clientID: id, clientSecret: nil)
    }

    @Test func `device code decodes the rfc 8628 response`() async throws {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "device-test"),
            response: StubURLProtocol.Response(
                body: """
                {
                    "device_code": "DEVICECODE123",
                    "user_code": "BDWP-HQPK",
                    "verification_uri": "https://simkl.com/pin",
                    "verification_uri_complete": "https://simkl.com/pin?user_code=BDWP-HQPK",
                    "expires_in": 900,
                    "interval": 5
                }
                """
            )
        )

        let code = try await makeClient(id: "device-test").requestDeviceCode()

        #expect(code.deviceCode == "DEVICECODE123")
        #expect(code.userCode == "BDWP-HQPK")
        #expect(code.verificationURL == "https://simkl.com/pin")
        #expect(code.verificationURLComplete == "https://simkl.com/pin?user_code=BDWP-HQPK")
        #expect(code.expiresIn == 900)
        #expect(code.interval == 5)
    }

    @Test func `activation url prefers the pre-filled variant`() {
        let code = SimklDeviceCode(
            deviceCode: "d", userCode: "BDWP-HQPK",
            verificationURL: "https://simkl.com/pin",
            verificationURLComplete: "https://simkl.com/pin?user_code=BDWP-HQPK",
            expiresIn: 900, interval: 5
        )
        #expect(SimklClient.activationURL(for: code)?.absoluteString == "https://simkl.com/pin?user_code=BDWP-HQPK")

        let bare = SimklDeviceCode(
            deviceCode: "d", userCode: "BDWP-HQPK",
            verificationURL: "https://simkl.com/pin",
            verificationURLComplete: nil,
            expiresIn: 900, interval: 5
        )
        #expect(SimklClient.activationURL(for: bare)?.absoluteString == "https://simkl.com/pin")
    }

    @Test func `pending poll maps to a retryable error`() async {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "pending-test"),
            response: StubURLProtocol.Response(status: 400, body: #"{"error": "authorization_pending", "error_description": "Waiting"}"#)
        )

        do {
            _ = try await makeClient(id: "pending-test").pollForToken(deviceCode: "d")
            Issue.record("Expected authorizationPending")
        } catch let error as SimklError {
            #expect(error == .authorizationPending)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func `slow down poll maps to a back-off error`() async {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "slow-test"),
            response: StubURLProtocol.Response(status: 400, body: #"{"error": "slow_down"}"#)
        )

        do {
            _ = try await makeClient(id: "slow-test").pollForToken(deviceCode: "d")
            Issue.record("Expected slowDown")
        } catch let error as SimklError {
            #expect(error == .slowDown)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func `expired poll maps to a restart error`() async {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "expired-test"),
            response: StubURLProtocol.Response(status: 400, body: #"{"error": "expired_token"}"#)
        )

        do {
            _ = try await makeClient(id: "expired-test").pollForToken(deviceCode: "d")
            Issue.record("Expected codeExpired")
        } catch let error as SimklError {
            #expect(error == .codeExpired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func `an unregistered v1 client id maps to invalid client`() async {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "v1-test"),
            response: StubURLProtocol.Response(
                status: 401,
                body: #"{"error": "invalid_client", "error_description": "This client_id is not enabled for OAuth 2.0"}"#
            )
        )

        do {
            _ = try await makeClient(id: "v1-test").pollForToken(deviceCode: "d")
            Issue.record("Expected invalidClient")
        } catch let error as SimklError {
            #expect(error == .invalidClient)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func `approved poll decodes the token set`() async throws {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "approved-test"),
            response: StubURLProtocol.Response(
                body: """
                {
                    "access_token": "simkl_at_abc",
                    "token_type": "Bearer",
                    "expires_in": 604800,
                    "refresh_token": "simkl_rt_def",
                    "scope": "media:read media:write"
                }
                """
            )
        )

        let response = try await makeClient(id: "approved-test").pollForToken(deviceCode: "d")
        let tokens = response.tokens
        #expect(tokens.accessToken == "simkl_at_abc")
        #expect(tokens.refreshToken == "simkl_rt_def")
        #expect(tokens.expiresIn == 604_800)
        #expect(tokens.scope == "media:read media:write")
        #expect(tokens.needsRefresh == false)
    }

    @Test func `refresh decodes the token set`() async throws {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "refresh-test"),
            response: StubURLProtocol.Response(
                body: """
                {
                    "access_token": "simkl_at_new",
                    "token_type": "Bearer",
                    "expires_in": 604800,
                    "refresh_token": "simkl_rt_def",
                    "scope": "media:read media:write"
                }
                """
            )
        )

        let response = try await makeClient(id: "refresh-test").refreshToken("simkl_rt_def")
        #expect(response.tokens.accessToken == "simkl_at_new")
    }

    @Test func `all items decode movies shows and anime`() throws {
        let body = """
        {
            "movies": [
                {
                    "status": "completed",
                    "last_watched_at": "2014-08-09T07:25:55Z",
                    "movie": {"title": "Captain America", "ids": {"simkl": 55328, "tmdb": 1771}}
                },
                {
                    "status": "plantowatch",
                    "last_watched_at": null,
                    "movie": {"title": "Planned", "ids": {"tmdb": 999}}
                }
            ],
            "shows": [
                {
                    "status": "watching",
                    "last_watched_at": null,
                    "show": {"title": "Show", "ids": {"tmdb": "300"}},
                    "seasons": [
                        {"number": 1, "episodes": [{"number": 1, "watched_at": "2024-01-01T10:00:00Z"}, {"number": 2}]}
                    ]
                }
            ],
            "anime": [
                {
                    "status": "completed",
                    "show": {"title": "Anime", "ids": {"mal": 16498}},
                    "seasons": [{"number": 1, "episodes": [{"number": 1}]}]
                }
            ]
        }
        """

        let items = try JSONDecoder().decode(SimklAllItems.self, from: Data(body.utf8))

        #expect(items.movies.count == 2)
        #expect(items.movies[0].isWatched == true)
        #expect(items.movies[1].isWatched == false)
        #expect(items.shows.count == 2)
        #expect(items.shows[0].show.ids.tmdb == 300)
        #expect(items.shows[0].seasons[0].episodes[0].lastWatchedAt == "2024-01-01T10:00:00Z")
        #expect(items.shows[0].seasons[0].episodes[1].lastWatchedAt == nil)
        #expect(items.shows[1].show.ids.tmdb == nil)
    }

    @Test func `an empty library answers as no items`() async throws {
        StubURLProtocol.register(
            host: "api.simkl.com",
            query: ("client_id", "empty-test"),
            response: StubURLProtocol.Response(body: "null")
        )

        let items = try await makeClient(id: "empty-test").watchedItems(accessToken: "t")
        #expect(items.movies.isEmpty)
        #expect(items.shows.isEmpty)
    }
}
