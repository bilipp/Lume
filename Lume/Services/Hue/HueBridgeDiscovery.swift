//
//  HueBridgeDiscovery.swift
//  Lume
//
//  Bonjour discovery of Hue Bridges (`_hue._tcp`) on the local network. No
//  cloud lookup: a bridge Bonjour can't see is added by IP. Browses only
//  between `start()` and `stop()` — the Hue settings pane owns that window —
//  so the app never browses at launch or triggers the local-network prompt on
//  its own.
//

import Foundation
import Network

/// A bridge seen on the network. `host` is nil until the service resolves.
nonisolated struct DiscoveredHueBridge: Identifiable, Hashable {
    /// The Bonjour service name, unique per domain and therefore the identity.
    let name: String
    /// TXT `bridgeid`, lowercased to match the certificate's common name.
    let bridgeID: String?
    /// TXT `modelid`.
    let modelID: String?
    let host: String?

    var id: String {
        name
    }

    func resolved(to host: String?) -> DiscoveredHueBridge {
        DiscoveredHueBridge(name: name, bridgeID: bridgeID, modelID: modelID, host: host)
    }

    /// The bare host of a resolved `host:port` endpoint, scope removed.
    static func host(for endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let literal: String
        switch host {
        case let .ipv4(address):
            literal = "\(address)"
        case let .ipv6(address):
            literal = "\(address)"
        case let .name(name, _):
            literal = name
        @unknown default:
            return nil
        }
        let bare = literal.split(separator: "%").first.map(String.init) ?? ""
        return bare.isEmpty ? nil : bare
    }

    /// The bridge id from a TXT `bridgeid` value: 16 hex digits, lowercased.
    static func bridgeID(fromTXT value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 16, value.allSatisfy(\.isHexDigit)
        else { return nil }
        return value.lowercased()
    }
}

#if os(tvOS)
    import os

    nonisolated extension DiscoveredHueBridge: BonjourDiscoveredService {
        init(name: String, txtRecord: NWTXTRecord?) {
            self.init(
                name: name,
                bridgeID: Self.bridgeID(fromTXT: txtRecord?["bridgeid"]),
                modelID: txtRecord?["modelid"],
                host: nil
            )
        }

        var address: String? {
            host
        }

        static func address(for endpoint: NWEndpoint) -> String? {
            host(for: endpoint)
        }
    }

    /// Resolves to the bare host `HueBridgeClient` takes.
    typealias HueBridgeDiscovery = BonjourServiceBrowser<DiscoveredHueBridge>

    extension BonjourServiceBrowser where Item == DiscoveredHueBridge {
        /// A no-op under tests and previews.
        convenience init() {
            self.init(
                serviceType: "_hue._tcp",
                logger: Logger.network,
                logLabel: "Hue discovery",
                describeError: { LogRedaction.describe($0) },
                isBrowsingAllowed: { !LumeApp.isTestOrPreviewHost }
            )
        }

        var bridges: [DiscoveredHueBridge] {
            services
        }
    }
#endif
