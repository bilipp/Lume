//
//  RecordingServerDiscovery.swift
//  Lume
//
//  Bonjour discovery of LumeRecorder servers on the local network. Browses only
//  between `start()` and `stop()` — the pairing screen owns that window — so the
//  app never browses in the background or triggers the local-network prompt on
//  its own.
//

import Foundation
import LumeRecorderKit
import Network
import os

/// A server seen on the network. `baseURL` is `nil` until the service resolves.
nonisolated struct DiscoveredRecordingServer: Identifiable, Hashable {
    /// The Bonjour service name, unique per domain and therefore the identity.
    let name: String
    /// TXT `id` — the server's stable identity, matched against a paired config.
    let serverID: UUID?
    /// TXT `version`.
    let version: String?
    /// TXT `api`.
    let apiVersion: Int?
    let baseURL: URL?

    var id: String {
        name
    }

    func resolved(to baseURL: URL?) -> DiscoveredRecordingServer {
        DiscoveredRecordingServer(
            name: name, serverID: serverID, version: version, apiVersion: apiVersion, baseURL: baseURL
        )
    }
}

nonisolated extension DiscoveredRecordingServer: BonjourDiscoveredService {
    init(name: String, txtRecord: NWTXTRecord?) {
        self.init(
            name: name,
            serverID: txtRecord?["id"].flatMap(UUID.init(uuidString:)),
            version: txtRecord?["version"],
            apiVersion: txtRecord?["api"].flatMap { Int($0) },
            baseURL: nil
        )
    }

    var address: URL? {
        baseURL
    }

    static func address(for endpoint: NWEndpoint) -> URL? {
        baseURL(for: endpoint)
    }

    /// The base URL for a resolved `host:port` endpoint.
    static func baseURL(for endpoint: NWEndpoint) -> URL? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        switch host {
        case let .ipv4(address):
            let literal = "\(address)".split(separator: "%").first.map(String.init) ?? ""
            return LumeRecorderClient.normalizedBaseURL(from: "http://\(literal):\(port.rawValue)")
        case let .ipv6(address):
            let literal = "\(address)".replacingOccurrences(of: "%", with: "%25")
            return URL(string: "http://[\(literal)]:\(port.rawValue)")
        case let .name(name, _):
            return LumeRecorderClient.normalizedBaseURL(from: "http://\(name):\(port.rawValue)")
        @unknown default:
            return nil
        }
    }
}

/// Resolves to an `http://host:port` base URL, which syncs to the user's other
/// devices.
typealias RecordingServerDiscovery = BonjourServiceBrowser<DiscoveredRecordingServer>

extension BonjourServiceBrowser where Item == DiscoveredRecordingServer {
    convenience init() {
        self.init(
            serviceType: LumeRecorderClient.bonjourServiceType,
            logger: Logger.recording,
            logLabel: "Recording server discovery",
            describeError: { String(describing: $0) }
        )
    }

    var servers: [DiscoveredRecordingServer] {
        services
    }
}
