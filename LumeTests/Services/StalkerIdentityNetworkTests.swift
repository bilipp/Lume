import Foundation
@testable import Lume
import Testing

struct StalkerIdentityNetworkTests {
    private func items(_ request: URLRequest) -> [URLQueryItem] {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }

    private func makeClient(host: String, identity: StalkerIdentity = StalkerIdentity(), password: String = "") -> StalkerClient {
        StalkerClient(
            configuration: .init(
                portalURL: "https://\(host)/stalker_portal/", macAddress: "00:1a:79:00:00:01",
                username: password.isEmpty ? "" : "SYNTHETIC-USER", password: password, identity: identity
            ), urlSession: StubURLProtocol.makeSession()
        )
    }

    private static func response(_ request: URLRequest) -> StubURLProtocol.Response {
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        switch query.first(where: { $0.name == "action" })?.value {
        case "handshake": return .init(body: #"{"js":{"token":"SYNTHETIC-TOKEN"}}"#)
        case "get_profile": return .init(body: #"{"js":{"status":0}}"#)
        case "get_all_channels": return .init(body: #"{"js":{"data":[{"id":"1","name":"Synthetic","cmd":"ffmpeg http://localhost/ch/1"}]}}"#)
        case "create_link": return .init(body: #"{"js":{"cmd":"https://media.example.invalid/1.ts"}}"#)
        default: return .init(body: #"{"js":[]}"#)
        }
    }

    @Test func `a MAC-only config omits all optional identity fields and retains original headers`() async throws {
        let host = "mac-only.identity.test"
        StubURLProtocol.register(host: host, handler: Self.response)
        let client = makeClient(host: host)
        _ = try await client.authenticate()
        _ = try await client.getAllChannels()
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 3)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "SN") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "mac=00:1a:79:00:00:01; stb_lang=en; timezone=Europe/London")
            #expect(request.value(forHTTPHeaderField: "X-User-Agent") == "Model: MAG250; Link: WiFi")
            #expect(Set(items(request).map(\.name)).isDisjoint(with: ["sn", "device_id", "device_id2", "signature", "signature2"]))
        }
    }

    @Test func `literal identity is profile scoped and retained by catalogue and playback clients`() async throws {
        let host = "advanced.identity.test"
        let identity = StalkerIdentity(
            serialNumber: "SYNTHETIC-SERIAL", deviceId1: "  ONE &+%=/?  ",
            deviceId2: "", signature1: "SYNTHETIC-SIGNATURE+&%", signature2: "TWO"
        )
        StubURLProtocol.register(host: host, handler: Self.response)
        _ = try await makeClient(host: host, identity: identity).authenticate()
        _ = try await makeClient(host: host, identity: identity).getAllChannels()
        _ = try await makeClient(host: host, identity: identity).resolveStreamURL(type: .itv, cmd: "ffmpeg http://localhost/ch/1")
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 4)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "SN") == identity.serialNumber)
            if items(request).contains(URLQueryItem(name: "action", value: "get_profile")) {
                for item in identity.profileQuery {
                    #expect(items(request).contains(item))
                }
                #expect(request.url?.absoluteString.contains("%2B") == true)
                #expect(request.url?.absoluteString.contains("+") == false)
            } else {
                #expect(Set(items(request).map(\.name)).isDisjoint(with: ["sn", "device_id", "device_id2", "signature", "signature2"]))
            }
        }
    }

    @Test func `one token refresh retains identity and bounds repeated unauthorized responses`() async throws {
        let host = "refresh.identity.test"
        let identity = StalkerIdentity(serialNumber: "", deviceId1: "ONE", deviceId2: "TWO", signature1: "")
        StubURLProtocol.register(host: host) { request in
            if request.url?.absoluteString.contains("action=get_all_channels") == true { return .init(status: 401) }
            return Self.response(request)
        }
        let client = makeClient(host: host, identity: identity)
        await #expect(throws: StalkerError.self) { try await client.getAllChannels() }
        let requests = StubURLProtocol.requests(host: host)
        let profiles = requests.filter { items($0).contains(URLQueryItem(name: "action", value: "get_profile")) }
        #expect(profiles.count == 2)
        #expect(requests.count == 6)
        for request in profiles {
            for item in identity.profileQuery {
                #expect(items(request).contains(item))
            }
        }
    }

    @Test func `credential edit cannot reuse an authenticated session`() async throws {
        let host = "credentials.identity.test"
        StubURLProtocol.register(host: host, handler: Self.response)
        _ = try await makeClient(host: host).authenticate()
        _ = try await makeClient(host: host, password: "SYNTHETIC-NEW-PASSWORD").authenticate()
        #expect(StubURLProtocol.requests(host: host).count(where: {
            items($0).contains(URLQueryItem(name: "action", value: "handshake"))
        }) == 2)
    }

    @Test func `an HTTP 200 blocked profile stops discovery and never reaches catalogue`() async {
        let host = "blocked.identity.test"
        StubURLProtocol.register(host: host) { request in
            if request.url?.absoluteString.contains("action=get_profile") == true {
                return .init(body: #"{"js":{"status":1,"msg":"SYNTHETIC-PRIVATE-SERIAL","block_msg":"SYNTHETIC-TOKEN"}}"#)
            }
            return Self.response(request)
        }
        let client = makeClient(host: host, identity: StalkerIdentity(deviceId1: "ONE"))
        await #expect(throws: StalkerError.self) { try await client.getAllChannels() }
        #expect(StubURLProtocol.requests(host: host).count == 2)
        #expect(await StalkerSessionStore.shared.session(for: client.configuration.sessionKey) == nil)
    }

    @Test func `login required profile uses configured ids and one checked second step`() async throws {
        let host = "login-step.identity.test"
        let identity = StalkerIdentity(serialNumber: "SERIAL", deviceId1: "ONE", deviceId2: "TWO", signature2: "SIG2")
        StubURLProtocol.register(host: host) { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            if query.contains(URLQueryItem(name: "action", value: "get_profile")) {
                return .init(body: query.contains(URLQueryItem(name: "auth_second_step", value: "1"))
                    ? #"{"js":{"status":0}}"# : #"{"js":{"status":2,"msg":"login required"}}"#)
            }
            if query.contains(URLQueryItem(name: "action", value: "do_auth")) { return .init(body: #"{"js":true}"#) }
            return Self.response(request)
        }
        _ = try await makeClient(host: host, identity: identity, password: "PASSWORD").authenticate()
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 4)
        let auth = try #require(requests.first { items($0).contains(URLQueryItem(name: "action", value: "do_auth")) })
        #expect(items(auth).contains(URLQueryItem(name: "device_id", value: "ONE")))
        #expect(items(auth).contains(URLQueryItem(name: "device_id2", value: "TWO")))
        #expect(!items(auth).contains(where: { $0.name == "signature2" || $0.name == "sn" }))
    }

    @Test func `canonical explicit endpoint paths and installation prefixes survive`() {
        for path in ["/server/load.php", "/stalker_portal/server/load.php", "/custom/server/load.php", "/Custom/portal.php"] {
            let input = "https://portal.example.invalid:8443" + path
            #expect(StalkerClient.candidateEndpoints(for: input).first?.absoluteString == input)
        }
        #expect(StalkerClient.candidateEndpoints(for: "https://portal.example.invalid/stalker_portal/").first?.path
            == "/stalker_portal/server/load.php")
    }

    @Test func `concurrent catalogue callers share one checked handshake`() async throws {
        let host = "single-flight.identity.test"
        StubURLProtocol.register(host: host, handler: Self.response)
        let first = makeClient(host: host, identity: StalkerIdentity(deviceId1: "ONE"))
        let second = makeClient(host: host, identity: StalkerIdentity(deviceId1: "ONE"))
        async let channels = first.getAllChannels()
        async let genres = second.getLiveGenres()
        _ = try await (channels, genres)
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count(where: { items($0).contains(URLQueryItem(name: "action", value: "handshake")) }) == 1)
        #expect(requests.count(where: { items($0).contains(URLQueryItem(name: "action", value: "get_profile")) }) == 1)
    }

    @Test func `token plus an empty HTTP 200 profile is not authenticated`() async {
        let host = "empty-profile.identity.test"
        StubURLProtocol.register(host: host) { request in
            if request.url?.absoluteString.contains("action=get_profile") == true { return .init(body: #"{"js":{}}"#) }
            return Self.response(request)
        }
        let client = makeClient(host: host)
        await #expect(throws: StalkerError.self) { try await client.authenticate() }
        #expect(await StalkerSessionStore.shared.session(for: client.configuration.sessionKey) == nil)
        #expect(StubURLProtocol.requests(host: host).count == 2)
    }
}
