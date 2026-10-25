//
//  RecordingServerBackend.swift
//  Lume
//
//  The backend-agnostic seam the app talks to for DVR work. Every backend maps
//  its own wire DTOs into the app's recording value types
//  (`RecordingServerTypes.swift`), so nothing above this seam depends on one
//  server's client.
//
//  Every method throws `RecordingServerError` only, so callers never see a
//  backend-specific error. Implementations never retry: a `POST`/`DELETE` that
//  failed in flight may still have landed, and only the caller knows whether
//  re-sending (with the same idempotency key) is safe.
//

import Foundation
import LumeRecorderKit

nonisolated protocol RecordingServerBackend: Sendable {
    var kind: RecordingServerKind { get }

    /// What the backend supports, before any account permissions are known.
    var capabilities: RecordingServerCapabilities { get }

    /// `capabilities` narrowed to what the signed-in account may do. Fails
    /// with `.forbidden` for an account that may not even list recordings.
    func accountCapabilities() async throws(RecordingServerError) -> RecordingServerCapabilities

    /// Identity check; fails with `.unsupportedAPIVersion` for a server this
    /// build cannot talk to.
    func serverInfo() async throws(RecordingServerError) -> ServerIdentity

    /// `nil` when the server reports no load figures. Called only when
    /// `capabilities.hasStatusEndpoint`.
    func status() async throws(RecordingServerError) -> RecordingServerStatus?

    func recordings() async throws(RecordingServerError) -> [ServerRecording]

    /// Creates a record-now (`start` ≤ now) or scheduled recording. Pass a fresh
    /// key per user action; re-sending the same key returns the first result.
    /// A target this backend can't record from fails with `.invalidRequest`.
    func createRecording(
        _ request: RecordingCreateRequest,
        idempotencyKey: String
    ) async throws(RecordingServerError) -> ServerRecording

    /// Cancels a scheduled recording or ends a running one.
    func stopRecording(id: RecordingID) async throws(RecordingServerError) -> ServerRecording

    func deleteRecording(id: RecordingID) async throws(RecordingServerError)

    /// Where to play a recording, and the headers that URL needs. Fails with
    /// `.notPlayableYet` before the first segment exists.
    func playback(id: RecordingID) async throws(RecordingServerError) -> RecordingPlayback
}

/// A backend that pairs devices by a one-time code and can revoke them.
nonisolated protocol RecordingServerDevicePairing: RecordingServerBackend {
    /// Exchanges the server's one-time code for a token. A wrong or expired
    /// code fails with `.invalidPairingCode`.
    func pair(code: String, deviceName: String) async throws(RecordingServerError) -> RecordingServerPairing

    /// Revokes a paired device's token on the server.
    func unpair(deviceID: UUID) async throws(RecordingServerError)
}

/// A backend that records the channels it serves, by its own channel ids.
nonisolated protocol RecordingServerChannelResolving: RecordingServerBackend {
    /// The server's own id for the channel it streams at
    /// `/proxy/ts/stream/<uuid>`; `nil` when it has none.
    func channelID(forStreamUUID uuid: UUID) async -> Int?
}

nonisolated extension RecordingServerBackend {
    var capabilities: RecordingServerCapabilities {
        kind.capabilities
    }

    func accountCapabilities() async throws(RecordingServerError) -> RecordingServerCapabilities {
        capabilities
    }

    func status() async throws(RecordingServerError) -> RecordingServerStatus? {
        nil
    }
}

nonisolated extension RecordingServerKind {
    /// The port an address typed without one gets.
    var defaultPort: Int {
        switch self {
        case .lumeRecorder: LumeRecorderClient.defaultPort
        case .dispatcharr: DispatcharrClient.defaultPort
        }
    }

    /// A typed address as a base URL: `http://` when no scheme is given, this
    /// kind's default port when an http address names none. `nil` for anything
    /// but an http(s) host.
    func normalizedBaseURL(from userInput: String) -> URL? {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.range(of: "://") == nil ? "http://" + trimmed : trimmed
        guard let parsed = URLComponents(string: candidate),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty
        else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = parsed.port {
            guard (1 ... 65535).contains(port) else { return nil }
            components.port = port
        } else if scheme == "http" {
            components.port = defaultPort
        }
        return components.url
    }
}

nonisolated extension URLSession {
    /// A LAN recording server answers in milliseconds or not at all, so fail
    /// fast instead of letting an unreachable host hold a UI action for the
    /// default minute. Never XtreamClient's single-connection session, whose
    /// one slot belongs to the provider.
    static let recordingServer: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
}

/// Everything needed to reach one server, snapshotted off the SwiftData row so
/// it can cross to a background task.
nonisolated struct RecordingServerEndpoint: Hashable {
    let kind: RecordingServerKind
    let baseURL: URL
    /// `nil` before pairing.
    let token: String?
    /// `token` decoded once, for a Dispatcharr endpoint only.
    let dispatcharrCredential: DispatcharrCredential?

    init(kind: RecordingServerKind, baseURL: URL, token: String?) {
        self.kind = kind
        self.baseURL = baseURL
        self.token = token
        dispatcharrCredential = kind == .dispatcharr ? token.flatMap(DispatcharrCredential.init(token:)) : nil
    }

    /// Whether `token` is a credential this kind can sign in with.
    var hasUsableCredential: Bool {
        switch kind {
        case .lumeRecorder: token?.isEmpty == false
        case .dispatcharr: dispatcharrCredential != nil
        }
    }

    func makeBackend() -> any RecordingServerBackend {
        switch kind {
        case .lumeRecorder:
            LumeRecorderBackend(baseURL: baseURL, token: token)
        case .dispatcharr:
            DispatcharrBackend(baseURL: baseURL, credential: dispatcharrCredential)
        }
    }

    func withToken(_ token: String?) -> RecordingServerEndpoint {
        RecordingServerEndpoint(kind: kind, baseURL: baseURL, token: token)
    }
}

nonisolated extension RecordingServerEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    /// Kind and token presence only: the base URL is a LAN address and the token
    /// is a bearer credential (for Dispatcharr, an API key or a password),
    /// none of which belongs in a log line.
    var description: String {
        "RecordingServerEndpoint(\(kind.rawValue), token: \(token == nil ? "none" : "<redacted>"))"
    }

    var debugDescription: String {
        description
    }
}
