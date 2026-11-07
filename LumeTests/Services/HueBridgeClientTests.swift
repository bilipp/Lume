//
//  HueBridgeClientTests.swift
//  LumeTests
//
//  `HueBridgeClient` against the canned bridge answers in
//  `LumeTests/Fixtures/Hue/`, and the pure trust rule behind
//  `HueTrustDelegate`. Each test talks to its own host so the shared stub
//  protocol keeps suites independent.
//

import CryptoKit
import Foundation
@testable import Lume
import Security
import Testing

struct HueBridgeClientTests {
    private static let applicationKey = "fixture-application-key-0000000000000000"
    private static let tvAreaID = "8d199a37-5ce4-4aae-a60e-db5d0aa27df3"
    private static let stripID = "6a1f0c2d-0000-4000-8000-000000000001"
    private static let playID = "6a1f0c2d-0000-4000-8000-000000000002"

    // MARK: - Address

    @Test(arguments: [
        ("192.168.178.24", "https://192.168.178.24"),
        (" hue-bridge.local ", "https://hue-bridge.local"),
        ("fe80::1", "https://[fe80::1]")
    ])
    func `hosts become https base URLs`(host: String, expected: String) {
        #expect(HueBridgeClient.baseURL(host: host)?.absoluteString == expected)
    }

    @Test(arguments: ["", "http://192.168.1.2", "192.168.1.2/api", "192.168.1.2:8443", "user@bridge", "a b"])
    func `anything but a bare host is rejected`(host: String) {
        #expect(HueBridgeClient.baseURL(host: host) == nil)
    }

    // MARK: - Pairing

    @Test func `identify reads the unauthenticated config`() async throws {
        let (client, host) = try makeClient(applicationKey: nil)
        let body = try hueFixture("hue-config.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let config = try await client.identify()

        #expect(config.bridgeID == "001788FFFE000000")
        #expect(config.normalizedID == "001788fffe000000")
        #expect(config.modelID == "BSB002")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.path(percentEncoded: false) == "/api/0/config")
        #expect(request.value(forHTTPHeaderField: "hue-application-key") == nil)
    }

    @Test func `pairing posts the Apple TV device type and returns both keys`() async throws {
        let (client, host) = try makeClient(applicationKey: nil)
        let body = try hueFixture("hue-pairing-success.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let credentials = try await client.pair()

        #expect(credentials.applicationKey == Self.applicationKey)
        #expect(credentials.clientKey == "00112233445566778899AABBCCDDEEFF")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path(percentEncoded: false) == "/api")
        let sent = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["devicetype"] as? String == "lume#appletv")
        #expect(json["generateclientkey"] as? Bool == true)
    }

    @Test func `error 101 means the link button wasn't pressed`() async throws {
        let (client, host) = try makeClient(applicationKey: nil)
        let body = try hueFixture("hue-pairing-link-button.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        await #expect(throws: HueBridgeError.linkButtonNotPressed) {
            try await client.pair()
        }
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    @Test func `other pairing errors carry their type only`() async throws {
        let (client, host) = try makeClient(applicationKey: nil)
        StubURLProtocol.register(host: host) { _ in
            .init(body: #"[{"error":{"type":7,"address":"/","description":"invalid value"}}]"#)
        }

        await #expect(throws: HueBridgeError.pairingFailed(type: 7)) {
            try await client.pair()
        }
    }

    // MARK: - CLIP v2

    @Test func `entertainment areas decode with the key header`() async throws {
        let (client, host) = try makeClient()
        let body = try hueFixture("hue-entertainment-configurations.json")
        StubURLProtocol.register(host: host) { _ in .init(body: body) }

        let areas = try await client.entertainmentConfigurations()

        #expect(areas.map(\.name) == ["TV", "Bildschirm"])
        let tvArea = try #require(areas.first)
        #expect(tvArea.id == Self.tvAreaID)
        #expect(tvArea.configurationType == "screen")
        #expect(tvArea.channels.map(\.channelID) == [0, 1])
        #expect(tvArea.channels.first?.position == HuePosition(x: 0.47, y: 1.0, z: -1.0))
        #expect(areas.last?.configurationType == "monitor")
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.path(percentEncoded: false) == "/clip/v2/resource/entertainment_configuration")
        #expect(request.value(forHTTPHeaderField: "hue-application-key") == Self.applicationKey)
    }

    @Test func `entertainment services resolve an area's lights`() async throws {
        let (client, host) = try makeClient()
        let areas = try hueFixture("hue-entertainment-configurations.json")
        let services = try hueFixture("hue-entertainment-services.json")
        StubURLProtocol.register(host: host) { request in
            request.url?.path().hasSuffix("/entertainment") == true ? .init(body: services) : .init(body: areas)
        }

        let tvArea = try #require(try await client.entertainmentConfigurations().first)
        let resolved = try await client.entertainmentServices()

        #expect(resolved.count == 3)
        #expect(tvArea.lightIDs(entertainmentServices: resolved) == [Self.stripID, Self.playID] as Set)
    }

    @Test func `starting an idle area checks it, then puts start`() async throws {
        let (client, host) = try makeClient()
        let areas = try hueFixture("hue-entertainment-configurations.json")
        let accepted = try hueFixture("hue-put-ok.json")
        StubURLProtocol.register(host: host) { request in
            request.httpMethod == "PUT" ? .init(body: accepted) : .init(body: areas)
        }

        try await client.startStreaming(areaID: Self.tvAreaID)

        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        let put = try #require(requests.last)
        #expect(put.url?.path(percentEncoded: false) == "/clip/v2/resource/entertainment_configuration/\(Self.tvAreaID)")
        #expect(try body(of: put) == ["action": "start"])
    }

    @Test func `an area another app streams to is left alone`() async throws {
        let (client, host) = try makeClient()
        let active = try hueFixture("hue-entertainment-configuration-active.json")
        StubURLProtocol.register(host: host) { _ in .init(body: active) }

        await #expect(throws: HueBridgeError.areaInUse) {
            try await client.startStreaming(areaID: Self.tvAreaID)
        }
        #expect(StubURLProtocol.requests(host: host).map(\.httpMethod) == ["GET"])
    }

    @Test(arguments: [(409, "{}"), (200, #"{"errors":[{"description":"busy"}],"data":[]}"#)])
    func `a refused start reads as in use`(status: Int, refusal: String) async throws {
        let (client, host) = try makeClient()
        let areas = try hueFixture("hue-entertainment-configurations.json")
        StubURLProtocol.register(host: host) { request in
            request.httpMethod == "PUT" ? .init(status: status, body: refusal) : .init(body: areas)
        }

        await #expect(throws: HueBridgeError.areaInUse) {
            try await client.startStreaming(areaID: Self.tvAreaID)
        }
    }

    @Test func `stop puts stop`() async throws {
        let (client, host) = try makeClient()
        let accepted = try hueFixture("hue-put-ok.json")
        StubURLProtocol.register(host: host) { _ in .init(body: accepted) }

        try await client.stopStreaming(areaID: Self.tvAreaID)

        let put = try #require(StubURLProtocol.requests(host: host).first)
        #expect(put.httpMethod == "PUT")
        #expect(try body(of: put) == ["action": "stop"])
    }

    @Test func `ids that aren't UUIDs never reach a path`() async throws {
        let (client, host) = try makeClient()
        StubURLProtocol.register(host: host) { _ in .init(body: "{}") }

        await #expect(throws: HueBridgeError.invalidRequest) {
            try await client.stopStreaming(areaID: "../light")
        }
        await #expect(throws: HueBridgeError.invalidRequest) {
            try await client.updateLight(id: "1/2", HueLightUpdate(power: HueOnState(on: true)))
        }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }

    @Test func `restore puts every light's whole state without reading the bridge`() async throws {
        let (client, host) = try makeClient()
        let accepted = try hueFixture("hue-put-ok.json")
        StubURLProtocol.register(host: host) { _ in .init(body: accepted) }
        let snapshot = HueLightSnapshot(lights: [
            .init(lightID: Self.stripID, isOn: true, brightness: 62.5, color: .chromaticity(HueXY(x: 0.4573, y: 0.41))),
            .init(lightID: Self.playID, isOn: true, brightness: 40, color: .mirek(366))
        ])

        try await client.restore(snapshot)

        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.allSatisfy { $0.httpMethod == "PUT" })
        #expect(requests.map { $0.url?.path(percentEncoded: false) } == [
            "/clip/v2/resource/light/\(Self.stripID)",
            "/clip/v2/resource/light/\(Self.playID)"
        ])
        let sent = try JSONDecoder().decode(HueLightUpdate.self, from: #require(requests.last?.httpBody))
        #expect(sent == HueLightUpdate(
            power: HueOnState(on: true),
            dimming: .init(brightness: 40),
            colorTemperature: .init(mirek: 366)
        ))
    }

    @Test func `restore tries every light before throwing`() async throws {
        let (client, host) = try makeClient()
        let refused = try hueFixture("hue-put-error.json")
        StubURLProtocol.register(host: host) { _ in .init(status: 207, body: refused) }
        let snapshot = HueLightSnapshot(lights: [
            .init(lightID: Self.stripID, isOn: false, brightness: nil, color: nil),
            .init(lightID: Self.playID, isOn: true, brightness: nil, color: nil)
        ])

        await #expect(throws: HueBridgeError.rejected) {
            try await client.restore(snapshot)
        }
        #expect(StubURLProtocol.requests(host: host).count(where: { $0.httpMethod == "PUT" }) == 2)
    }

    @Test func `an unknown key is unauthorized`() async throws {
        let (client, host) = try makeClient()
        let body = try hueFixture("hue-error-403.json")
        StubURLProtocol.register(host: host) { _ in .init(status: 403, body: body) }

        await #expect(throws: HueBridgeError.unauthorized) {
            try await client.lights()
        }
    }

    @Test func `CLIP calls need a key`() async throws {
        let (client, host) = try makeClient(applicationKey: nil)
        StubURLProtocol.register(host: host) { _ in .init(body: "{}") }

        await #expect(throws: HueBridgeError.unauthorized) {
            try await client.lights()
        }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }

    @Test(arguments: [
        (400, HueBridgeError.invalidRequest),
        (404, .notFound),
        (429, .rateLimited),
        (503, .server(status: 503))
    ])
    func `status codes map to errors`(status: Int, expected: HueBridgeError) {
        #expect(HueBridgeClient.error(status: status) == expected)
    }

    @Test func `transport errors keep only their code`() {
        #expect(HueBridgeClient.error(.timedOut) == .transport(.timedOut))
        #expect(HueBridgeClient.error(.serverCertificateUntrusted) == .untrustedCertificate)
        #expect(HueBridgeClient.error(.cancelled) == .cancelled)
    }

    @Test func `descriptions never show the key`() throws {
        let (client, host) = try makeClient()
        for text in [String(describing: client), String(reflecting: client)] {
            #expect(!text.contains(Self.applicationKey))
            #expect(!text.contains(host))
        }
    }

    // MARK: - Helpers

    private func makeClient(applicationKey: String? = Self.applicationKey) throws -> (HueBridgeClient, String) {
        let host = "hue-\(UUID().uuidString.lowercased()).test"
        let client = try #require(
            HueBridgeClient(host: host, applicationKey: applicationKey, session: StubURLProtocol.makeSession())
        )
        return (client, host)
    }

    private func body(of request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

struct HueTrustTests {
    private static let bridgeID = "001788fffe000000"
    private static let leaf = Data(repeating: 0xAB, count: 32)

    private static func identity(
        commonName: String? = bridgeID,
        leaf: Data = leaf,
        signify: Bool
    ) -> HueServerIdentity {
        HueServerIdentity(commonName: commonName, leafSHA256: leaf, chainsToSignifyRoot: signify)
    }

    @Test func `a Signify chain naming the bridge is trusted`() {
        let decision = HueTrust.decide(
            Self.identity(commonName: "001788FFFE000000", signify: true),
            bridgeID: Self.bridgeID, pin: nil, allowsFirstUse: false
        )
        #expect(decision == .trusted)
    }

    @Test func `a Signify chain naming another bridge is rejected`() {
        let decision = HueTrust.decide(
            Self.identity(commonName: "001788fffe999999", signify: true),
            bridgeID: Self.bridgeID, pin: nil, allowsFirstUse: true
        )
        #expect(decision == .rejected)
    }

    @Test(arguments: [nil, "root-bridge", "192.168.178.24", "001788fffe00000"])
    func `a common name that isn't a bridge id is rejected`(name: String?) {
        let decision = HueTrust.decide(
            Self.identity(commonName: name, signify: true),
            bridgeID: nil, pin: nil, allowsFirstUse: true
        )
        #expect(decision == .rejected)
    }

    @Test func `an unknown bridge passes on its bridge-id common name`() {
        let decision = HueTrust.decide(
            Self.identity(signify: true), bridgeID: nil, pin: nil, allowsFirstUse: false
        )
        #expect(decision == .trusted)
    }

    @Test func `a self-signed bridge is pinned on first use while pairing`() {
        let decision = HueTrust.decide(
            Self.identity(signify: false), bridgeID: Self.bridgeID, pin: nil, allowsFirstUse: true
        )
        #expect(decision == .pinOnFirstUse(Self.leaf))
    }

    @Test func `a paired bridge never pins later`() {
        let decision = HueTrust.decide(
            Self.identity(signify: false), bridgeID: Self.bridgeID, pin: nil, allowsFirstUse: false
        )
        #expect(decision == .rejected)
    }

    @Test func `the pinned leaf is trusted, any other rejected`() {
        let pinned = HueTrust.decide(
            Self.identity(signify: false), bridgeID: Self.bridgeID, pin: Self.leaf, allowsFirstUse: false
        )
        let swapped = HueTrust.decide(
            Self.identity(leaf: Data(repeating: 0xCD, count: 32), signify: false),
            bridgeID: Self.bridgeID, pin: Self.leaf, allowsFirstUse: true
        )
        #expect(pinned == .trusted)
        #expect(swapped == .rejected)
    }

    @Test func `the embedded Signify root is the bridge CA`() throws {
        let der = try #require(HueTrust.signifyRootDER)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        #expect(name as String? == "root-bridge")
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        #expect(fingerprint == "F0BD8E6509E82F774D63BC009D5388C969FE3DCF7D6D541D6351B72B898D8ACF")
    }

    @Test func `the root's own chain verifies against itself`() throws {
        let der = try #require(HueTrust.signifyRootDER)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        let serverTrust = try #require(trust)
        let identity = try #require(HueTrust.identity(of: serverTrust))
        #expect(identity.commonName == "root-bridge")
        #expect(identity.chainsToSignifyRoot)
        #expect(identity.leafSHA256 == Data(SHA256.hash(data: der)))
    }
}

/// A committed Hue fixture, read from disk (not the test bundle, which
/// flattens resources).
private func hueFixture(_ name: String, filePath: String = #filePath) throws -> String {
    let url = repoRootURL(filePath: filePath).appendingPathComponent("LumeTests/Fixtures/Hue/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}
