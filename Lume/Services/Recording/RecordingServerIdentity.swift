//
//  RecordingServerIdentity.swift
//  Lume
//
//  A stable `serverID` for a backend whose server reports no identity of its
//  own (Dispatcharr). Every device signing in to the same server as the same
//  account derives the same id, so the CloudKit dedupe — keyed on `serverID` —
//  collapses their rows into one.
//

import CryptoKit
import Foundation

nonisolated enum RecordingServerIdentity {
    /// SHA-256 of `kind|host:port|user`, truncated to a version-8 UUID. `user`
    /// is the username, or a digest of the API key — never the key itself.
    static func uuid(kind: RecordingServerKind, host: String, port: Int, user: String) -> UUID {
        let seed = "\(kind.rawValue)|\(normalizedHost(host)):\(port)|\(user)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// `uuid(kind:host:port:user:)` for a base URL; one that names no port
    /// uses its scheme's.
    static func uuid(kind: RecordingServerKind, baseURL: URL, user: String) -> UUID {
        let (host, port) = hostAndPort(of: baseURL)
        return uuid(kind: kind, host: host, port: port, user: user)
    }

    /// The URL's normalized host, and its port or else its scheme's.
    static func hostAndPort(of url: URL) -> (host: String, port: Int) {
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return (normalizedHost(url.host(percentEncoded: false) ?? ""), port)
    }

    /// Host names are case-insensitive; a bracketed IPv6 literal and a fully
    /// qualified name with its trailing dot name the same host as without.
    private static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }
}
