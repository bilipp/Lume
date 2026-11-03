//
//  HueBridgeClient.swift
//  Lume
//
//  HTTPS client for the one paired Hue Bridge: pairing (`POST /api`), the
//  entertainment areas, opening and closing a stream, and reading and
//  restoring lights over CLIP v2. Each client owns an ephemeral session whose
//  delegate trusts only that bridge (`HueTrustDelegate`). Never retries —
//  the caller decides whether trying again is safe — and never logs a host,
//  key, id or response body; bridge prose is dropped, it can echo resource ids.
//

import Foundation

nonisolated enum HueBridgeError: Error, Hashable {
    /// Pairing error type 101.
    case linkButtonNotPressed
    /// The area streams to another app or a Sync Box.
    case areaInUse
    /// The application key is unknown to the bridge.
    case unauthorized
    case notFound
    case rateLimited
    /// The bridge's certificate failed `HueTrust`.
    case untrustedCertificate
    /// The address answered as a different bridge than expected.
    case wrongBridge
    case pairingFailed(type: Int)
    /// The bridge answered with CLIP errors.
    case rejected
    case server(status: Int)
    case transport(URLError.Code)
    case invalidRequest
    case invalidResponse
    case cancelled
}

/// The unauthenticated part of `GET /api/0/config`.
nonisolated struct HueBridgeConfig: Decodable, Hashable {
    var name: String
    /// Uppercase in this response; the certificate's common name is lowercase.
    var bridgeID: String
    var modelID: String?
    var apiVersion: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case bridgeID = "bridgeid"
        case modelID = "modelid"
        case apiVersion = "apiversion"
    }

    /// The bridge id as `HueBridgeAddress.id` stores it.
    var normalizedID: String {
        bridgeID.lowercased()
    }
}

nonisolated struct HueBridgeClient {
    let baseURL: URL
    private let applicationKey: String?
    private let transport: HueBridgeTransport

    /// Before pairing: identifies the bridge and pairs, pinning its leaf
    /// certificate when it isn't Signify-issued. `bridgeID` is nil for a
    /// typed address whose bridge isn't identified yet.
    static func pairing(host: String, bridgeID: String?) -> HueBridgeClient? {
        let delegate = HueTrustDelegate(bridgeID: bridgeID, pin: nil, allowsFirstUse: true)
        return HueBridgeClient(host: host, applicationKey: nil, transport: HueBridgeTransport(delegate: delegate))
    }

    /// A paired bridge.
    init?(bridge: HueBridgeAddress, secrets: HueBridgeSecrets) {
        let delegate = HueTrustDelegate(bridgeID: bridge.id, pin: secrets.certificatePin, allowsFirstUse: false)
        self.init(
            host: bridge.host,
            applicationKey: secrets.credentials.applicationKey,
            transport: HueBridgeTransport(delegate: delegate)
        )
    }

    /// Tests: `session` answers without a TLS handshake.
    init?(host: String, applicationKey: String?, session: URLSession) {
        self.init(host: host, applicationKey: applicationKey, transport: HueBridgeTransport(session: session))
    }

    private init?(host: String, applicationKey: String?, transport: HueBridgeTransport) {
        guard let baseURL = Self.baseURL(host: host) else { return nil }
        self.baseURL = baseURL
        self.applicationKey = applicationKey
        self.transport = transport
    }

    /// `https://<host>`, brackets added around an IPv6 literal. Nil for
    /// anything that isn't a bare host.
    static func baseURL(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("@"), !trimmed.contains(" ") else {
            return nil
        }
        let isIPv6Literal = trimmed.count(where: { $0 == ":" }) > 1 && !trimmed.hasPrefix("[")
        let authority = isIPv6Literal ? "[\(trimmed)]" : trimmed
        guard let url = URL(string: "https://\(authority)"), url.host() != nil, url.port == nil else { return nil }
        return url
    }

    /// The leaf pinned during this client's first handshake, to store in
    /// `HueBridgeSecrets.certificatePin` after pairing.
    var firstUsePin: Data? {
        transport.delegate?.handshake.firstUsePin
    }

    // MARK: - Endpoints

    /// Unauthenticated. Checks that the bridge reports the id its certificate
    /// names, so a typed address can't pass another bridge's certificate off.
    func identify() async throws(HueBridgeError) -> HueBridgeConfig {
        let config: HueBridgeConfig = try await decode(send(.get, "api/0/config", authenticated: false))
        if let delegate = transport.delegate {
            let handshake = delegate.handshake
            guard let commonName = handshake.commonName,
                  commonName.caseInsensitiveCompare(config.bridgeID) == .orderedSame
            else { throw .wrongBridge }
            if let expected = delegate.bridgeID, expected.caseInsensitiveCompare(config.bridgeID) != .orderedSame {
                throw .wrongBridge
            }
        }
        return config
    }

    /// One attempt; the caller polls while the user presses the link button.
    func pair(_ request: HuePairingRequest = .appleTV) async throws(HueBridgeError) -> HueBridgeCredentials {
        let data = try await send(.post, "api", json: request, authenticated: false)
        let outcome: HuePairingOutcome
        do {
            outcome = try HuePairingOutcome(responseData: data)
        } catch {
            throw .invalidResponse
        }
        switch outcome {
        case let .paired(credentials): return credentials
        case .linkButtonNotPressed: throw .linkButtonNotPressed
        case let .failed(type, _): throw .pairingFailed(type: type)
        }
    }

    func entertainmentConfigurations() async throws(HueBridgeError) -> [HueEntertainmentConfiguration] {
        try await resources("entertainment_configuration")
    }

    func entertainmentConfiguration(id: String) async throws(HueBridgeError) -> HueEntertainmentConfiguration {
        try Self.checkResourceID(id)
        guard let configuration = try await resources(
            "entertainment_configuration/\(id)", as: HueEntertainmentConfiguration.self
        ).first else { throw .notFound }
        return configuration
    }

    /// What channel members reference; resolves an area's lights.
    func entertainmentServices() async throws(HueBridgeError) -> [HueEntertainmentService] {
        try await resources("entertainment")
    }

    /// Opens streaming on an idle area. One another client streams to is
    /// left alone: no takeover.
    func startStreaming(areaID: String) async throws(HueBridgeError) {
        guard try await !entertainmentConfiguration(id: areaID).isStreaming else { throw .areaInUse }
        do {
            try await write("entertainment_configuration/\(areaID)", HueEntertainmentAction.start)
        } catch .rejected, .server(status: 409) {
            throw .areaInUse
        }
    }

    func stopStreaming(areaID: String) async throws(HueBridgeError) {
        try Self.checkResourceID(areaID)
        try await write("entertainment_configuration/\(areaID)", HueEntertainmentAction.stop)
    }

    func lights() async throws(HueBridgeError) -> [HueLight] {
        try await resources("light")
    }

    func updateLight(id: String, _ update: HueLightUpdate) async throws(HueBridgeError) {
        try Self.checkResourceID(id)
        try await write("light/\(id)", update)
    }

    /// Puts back what `snapshot` captured, light by light. Every light is
    /// tried; the first failure is thrown after.
    func restore(_ snapshot: HueLightSnapshot) async throws(HueBridgeError) {
        var firstError: HueBridgeError?
        for restore in snapshot.restoreUpdates {
            do {
                try await updateLight(id: restore.lightID, restore.update)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Transport

    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
    }

    /// CLIP v2 ids are UUIDs; anything else never reaches a request path.
    private static func checkResourceID(_ id: String) throws(HueBridgeError) {
        guard UUID(uuidString: id) != nil else { throw .invalidRequest }
    }

    private func resources<T: Decodable>(_ path: String, as _: T.Type = T.self) async throws(HueBridgeError) -> [T] {
        let response: HueResponse<T> = try await decode(send(.get, "clip/v2/resource/\(path)"))
        guard response.errors.isEmpty || !response.data.isEmpty else { throw .rejected }
        return response.data
    }

    private func write(_ path: String, _ body: some Encodable) async throws(HueBridgeError) {
        let response: HueResponse<HueResourceReference> = try await decode(
            send(.put, "clip/v2/resource/\(path)", json: body)
        )
        guard response.errors.isEmpty else { throw .rejected }
    }

    private func send(
        _ method: Method,
        _ path: String,
        json body: some Encodable,
        authenticated: Bool = true
    ) async throws(HueBridgeError) -> Data {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw .invalidRequest
        }
        return try await send(method, path, body: data, authenticated: authenticated)
    }

    private func send(
        _ method: Method,
        _ path: String,
        body: Data? = nil,
        authenticated: Bool = true
    ) async throws(HueBridgeError) -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let applicationKey else { throw .unauthorized }
            request.setValue(applicationKey, forHTTPHeaderField: "hue-application-key")
        }
        return try await Self.check(load(request))
    }

    private func load(_ request: URLRequest) async throws(HueBridgeError) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HueBridgeError.invalidResponse }
            return (data, http)
        } catch let error as HueBridgeError {
            throw error
        } catch let error as URLError {
            if transport.delegate?.handshake.rejected == true { throw .untrustedCertificate }
            throw Self.error(error.code)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .invalidResponse
        }
    }

    static func error(_ code: URLError.Code) -> HueBridgeError {
        switch code {
        case .cancelled: .cancelled
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            .untrustedCertificate
        default: .transport(code)
        }
    }

    private static func check(_ result: (Data, HTTPURLResponse)) throws(HueBridgeError) -> Data {
        let (data, response) = result
        guard (200 ..< 300).contains(response.statusCode) else { throw error(status: response.statusCode) }
        return data
    }

    static func error(status: Int) -> HueBridgeError {
        switch status {
        case 400: .invalidRequest
        case 401, 403: .unauthorized
        case 404: .notFound
        case 429: .rateLimited
        default: .server(status: status)
        }
    }

    private func decode<T: Decodable>(_ data: Data, as _: T.Type = T.self) throws(HueBridgeError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .invalidResponse
        }
    }
}

/// Owns a client's session; invalidating it on release breaks the session's
/// strong reference to its delegate.
private final nonisolated class HueBridgeTransport: Sendable {
    /// A LAN bridge answers in milliseconds or not at all.
    static let requestTimeout: TimeInterval = 8
    static let resourceTimeout: TimeInterval = 15

    let session: URLSession
    let delegate: HueTrustDelegate?

    init(delegate: HueTrustDelegate) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.delegate = delegate
    }

    init(session: URLSession) {
        self.session = session
        delegate = nil
    }

    deinit {
        if delegate != nil { session.finishTasksAndInvalidate() }
    }
}

/// Server only: the address is a LAN location and the key a secret.
nonisolated extension HueBridgeClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "HueBridgeClient(\(applicationKey == nil ? "unpaired" : "paired"))"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
