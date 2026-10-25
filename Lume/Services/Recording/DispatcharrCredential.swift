//
//  DispatcharrCredential.swift
//  Lume
//
//  How Lume signs in to a Dispatcharr server. Stored encoded in the existing
//  `SyncedRecordingServer.token` (cloud-encrypted) so Dispatcharr needs no new
//  CloudKit field. Lume never generates or revokes a Dispatcharr API key: the
//  server keeps one per user and generating replaces it.
//

import Foundation

nonisolated enum DispatcharrCredential: Hashable {
    /// A key the user generated in Dispatcharr, sent as `X-API-Key`.
    case apiKey(String)
    /// Lume mints short-lived JWTs from these and keeps them in memory only.
    case login(username: String, password: String)
}

nonisolated extension DispatcharrCredential {
    /// `nil` for anything but a complete credential — a LumeRecorder token, a
    /// value from a newer encoding, or one with an empty field.
    init?(token: String) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(token.utf8)),
              decoded.isComplete
        else { return nil }
        self = decoded
    }

    /// The value stored in `SyncedRecordingServer.token`.
    var token: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var isComplete: Bool {
        switch self {
        case let .apiKey(key):
            !key.isEmpty
        case let .login(username, password):
            !username.isEmpty && !password.isEmpty
        }
    }

    /// The account part of `RecordingServerIdentity.uuid`: the username, or a
    /// digest of the key so the key itself never becomes an identifier.
    var identityUser: String {
        switch self {
        case let .apiKey(key):
            sha256Hex(key)
        case let .login(username, _):
            username
        }
    }
}

nonisolated extension DispatcharrCredential: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, apiKey, username, password
    }

    private enum Mode: String, Codable {
        case apiKey, login
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .type) {
        case .apiKey:
            self = try .apiKey(container.decode(String.self, forKey: .apiKey))
        case .login:
            self = try .login(
                username: container.decode(String.self, forKey: .username),
                password: container.decode(String.self, forKey: .password)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .apiKey(key):
            try container.encode(Mode.apiKey, forKey: .type)
            try container.encode(key, forKey: .apiKey)
        case let .login(username, password):
            try container.encode(Mode.login, forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        }
    }
}

/// Mode only: the key and password are secrets, and the username identifies
/// the account on a LAN server — none of them belongs in a log line or a dump.
nonisolated extension DispatcharrCredential: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    var description: String {
        switch self {
        case .apiKey: "DispatcharrCredential(apiKey: <redacted>)"
        case .login: "DispatcharrCredential(login: <redacted>)"
        }
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
