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
import Observation
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

@MainActor
@Observable
final class RecordingServerDiscovery {
    enum State: Equatable {
        case idle
        case browsing
        /// The browser is up but can't see the network yet — typically while
        /// the local-network prompt is open, or after it was declined. It keeps
        /// running and resumes on its own once access is allowed.
        case waitingForLocalNetwork
        /// Browsing failed for good; `start()` again to retry.
        case unavailable
    }

    private(set) var state: State = .idle
    private(set) var servers: [DiscoveredRecordingServer] = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var resolveTasks: [String: Task<Void, Never>] = [:]
    /// Bumped on every start/stop so callbacks from a torn-down browser are dropped.
    @ObservationIgnored private var generation = 0

    /// Starts browsing. A browser that is already up — browsing or waiting
    /// for local-network access — is kept; one that failed is replaced.
    func start() {
        guard browser == nil else { return }
        resetResults()
        generation += 1
        let token = generation
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: LumeRecorderClient.bonjourServiceType, domain: nil),
            using: .tcp
        )
        // Both handlers fire on the main queue the browser is started on.
        browser.stateUpdateHandler = { [weak self] browserState in
            MainActor.assumeIsolated { self?.handle(browserState, generation: token) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.handle(results, generation: token) }
        }
        self.browser = browser
        state = .browsing
        browser.start(queue: .main)
    }

    func stop() {
        generation += 1
        browser?.cancel()
        browser = nil
        resetResults()
        state = .idle
    }

    private func resetResults() {
        resolveTasks.values.forEach { $0.cancel() }
        resolveTasks = [:]
        endpoints = [:]
        servers = []
    }

    private func handle(_ browserState: NWBrowser.State, generation token: Int) {
        guard token == generation else { return }
        switch browserState {
        case .ready:
            state = .browsing
        case let .waiting(error):
            // Not final: the user may still tap Allow on the local-network
            // prompt, and the browser moves to `.ready` by itself when they do.
            let reason = String(describing: error)
            Logger.recording.log("Recording server discovery waiting: \(reason, privacy: .public)")
            state = .waitingForLocalNetwork
        case let .failed(error):
            let reason = String(describing: error)
            Logger.recording.error("Recording server discovery failed: \(reason, privacy: .public)")
            browser?.cancel()
            browser = nil
            state = .unavailable
        default:
            break
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>, generation token: Int) {
        guard token == generation else { return }
        var next: [DiscoveredRecordingServer] = []
        var seen: Set<String> = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, seen.insert(name).inserted else { continue }
            let known = servers.first { $0.name == name }
            let txt = Self.txtRecord(of: result)
            let server = DiscoveredRecordingServer(
                name: name,
                serverID: txt?["id"].flatMap(UUID.init(uuidString:)),
                version: txt?["version"],
                apiVersion: txt?["api"].flatMap { Int($0) },
                baseURL: endpoints[name] == result.endpoint ? known?.baseURL : nil
            )
            next.append(server)
            if endpoints[name] != result.endpoint || (server.baseURL == nil && resolveTasks[name] == nil) {
                endpoints[name] = result.endpoint
                resolve(name: name, endpoint: result.endpoint, generation: token)
            }
        }
        for gone in Set(endpoints.keys).subtracting(seen) {
            endpoints[gone] = nil
            resolveTasks.removeValue(forKey: gone)?.cancel()
        }
        servers = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func resolve(name: String, endpoint: NWEndpoint, generation token: Int) {
        resolveTasks[name]?.cancel()
        resolveTasks[name] = Task { [weak self] in
            let baseURL = await RecordingServerEndpointResolver.resolve(endpoint)
            guard !Task.isCancelled, let self, token == generation else { return }
            resolveTasks[name] = nil
            guard endpoints[name] == endpoint, let index = servers.firstIndex(where: { $0.name == name }) else { return }
            servers[index] = servers[index].resolved(to: baseURL)
        }
    }

    private static func txtRecord(of result: NWBrowser.Result) -> NWTXTRecord? {
        if case let .bonjour(record) = result.metadata {
            return record
        }
        return nil
    }
}

/// Turns a Bonjour service endpoint into an `http://host:port` base URL by
/// briefly connecting to it. IPv4 is tried first: the base URL syncs to the
/// user's other devices, and an IPv6 link-local address carries an interface
/// scope that means nothing on another device.
nonisolated enum RecordingServerEndpointResolver {
    static func resolve(_ endpoint: NWEndpoint) async -> URL? {
        if let url = await connect(to: endpoint, ipv4Only: true) {
            return url
        }
        guard !Task.isCancelled else { return nil }
        return await connect(to: endpoint, ipv4Only: false)
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

    private static let queue = DispatchQueue(label: "app.lume.recording.resolve")
    private static let timeout: DispatchTimeInterval = .seconds(5)

    private static func connect(to endpoint: NWEndpoint, ipv4Only: Bool) async -> URL? {
        let parameters = NWParameters.tcp
        if ipv4Only, let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let finished = OSAllocatedUnfairLock(initialState: false)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                let finish: @Sendable (URL?) -> Void = { url in
                    let first = finished.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    connection.cancel()
                    continuation.resume(returning: url)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(connection.currentPath?.remoteEndpoint.flatMap(baseURL(for:)))
                    case .failed, .waiting, .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
