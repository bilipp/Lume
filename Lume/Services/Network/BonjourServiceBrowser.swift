//
//  BonjourServiceBrowser.swift
//  Lume
//
//  Bonjour discovery of one service type on the local network, shared by the
//  recording-server and Hue Bridge pickers. Browses only between `start()` and
//  `stop()` — the screen that shows the results owns that window — so the app
//  never browses in the background or triggers the local-network prompt on its
//  own.
//

import Foundation
import Network
import Observation
import os

/// A service seen on the network. `address` is nil until the service resolves.
nonisolated protocol BonjourDiscoveredService: Identifiable, Hashable {
    associatedtype Address: Hashable

    /// The Bonjour service name, unique per domain and therefore the identity.
    var name: String { get }
    var address: Address? { get }

    init(name: String, txtRecord: NWTXTRecord?)
    func resolved(to address: Address?) -> Self
    /// The address for a resolved `host:port` endpoint.
    static func address(for endpoint: NWEndpoint) -> Address?
}

@MainActor
@Observable
final class BonjourServiceBrowser<Item: BonjourDiscoveredService> {
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
    private(set) var services: [Item] = []

    @ObservationIgnored private let serviceType: String
    @ObservationIgnored private let logger: LumeLogger
    @ObservationIgnored private let logLabel: String
    @ObservationIgnored private let describeError: (NWError) -> String
    @ObservationIgnored private let isBrowsingAllowed: () -> Bool
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var resolveTasks: [String: Task<Void, Never>] = [:]
    /// Bumped on every start/stop so callbacks from a torn-down browser are dropped.
    @ObservationIgnored private var generation = 0

    /// `isBrowsingAllowed` false makes `start()` a no-op.
    init(
        serviceType: String,
        logger: LumeLogger,
        logLabel: String,
        describeError: @escaping (NWError) -> String,
        isBrowsingAllowed: @escaping () -> Bool = { true }
    ) {
        self.serviceType = serviceType
        self.logger = logger
        self.logLabel = logLabel
        self.describeError = describeError
        self.isBrowsingAllowed = isBrowsingAllowed
    }

    /// Starts browsing. A browser that is already up — browsing or waiting
    /// for local-network access — is kept; one that failed is replaced.
    func start() {
        guard isBrowsingAllowed(), browser == nil else { return }
        resetResults()
        generation += 1
        let token = generation
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
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
        services = []
    }

    private func handle(_ browserState: NWBrowser.State, generation token: Int) {
        guard token == generation else { return }
        let label = logLabel
        switch browserState {
        case .ready:
            state = .browsing
        case let .waiting(error):
            // Not final: the user may still tap Allow on the local-network
            // prompt, and the browser moves to `.ready` by itself when they do.
            let reason = describeError(error)
            logger.log("\(label, privacy: .public) waiting: \(reason, privacy: .public)")
            state = .waitingForLocalNetwork
        case let .failed(error):
            let reason = describeError(error)
            logger.error("\(label, privacy: .public) failed: \(reason, privacy: .public)")
            browser?.cancel()
            browser = nil
            state = .unavailable
        default:
            break
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>, generation token: Int) {
        guard token == generation else { return }
        var next: [Item] = []
        var seen: Set<String> = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, seen.insert(name).inserted else { continue }
            let known = services.first { $0.name == name }
            let service = Item(name: name, txtRecord: Self.txtRecord(of: result))
                .resolved(to: endpoints[name] == result.endpoint ? known?.address : nil)
            next.append(service)
            if endpoints[name] != result.endpoint || (service.address == nil && resolveTasks[name] == nil) {
                endpoints[name] = result.endpoint
                resolve(name: name, endpoint: result.endpoint, generation: token)
            }
        }
        for gone in Set(endpoints.keys).subtracting(seen) {
            endpoints[gone] = nil
            resolveTasks.removeValue(forKey: gone)?.cancel()
        }
        services = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func resolve(name: String, endpoint: NWEndpoint, generation token: Int) {
        resolveTasks[name]?.cancel()
        resolveTasks[name] = Task { [weak self] in
            let address = await BonjourEndpointResolver.resolve(endpoint, as: Item.self)
            guard !Task.isCancelled, let self, token == generation else { return }
            resolveTasks[name] = nil
            guard endpoints[name] == endpoint, let index = services.firstIndex(where: { $0.name == name }) else { return }
            services[index] = services[index].resolved(to: address)
        }
    }

    private static func txtRecord(of result: NWBrowser.Result) -> NWTXTRecord? {
        if case let .bonjour(record) = result.metadata {
            return record
        }
        return nil
    }
}

/// Turns a Bonjour service endpoint into an address by briefly connecting to
/// it. IPv4 is tried first: the address is stored and reused across launches
/// (and devices), and an IPv6 link-local address only means something together
/// with its interface scope.
nonisolated enum BonjourEndpointResolver {
    static func resolve<Item: BonjourDiscoveredService>(_ endpoint: NWEndpoint, as _: Item.Type) async -> Item.Address? {
        if let address = await connect(to: endpoint, ipv4Only: true).flatMap(Item.address(for:)) {
            return address
        }
        guard !Task.isCancelled else { return nil }
        return await connect(to: endpoint, ipv4Only: false).flatMap(Item.address(for:))
    }

    private static let queue = DispatchQueue(label: "app.lume.bonjour.resolve")
    private static let timeout: DispatchTimeInterval = .seconds(5)

    /// The connection's resolved remote endpoint, or nil when it didn't connect.
    private static func connect(to endpoint: NWEndpoint, ipv4Only: Bool) async -> NWEndpoint? {
        let parameters = NWParameters.tcp
        if ipv4Only, let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let finished = OSAllocatedUnfairLock(initialState: false)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NWEndpoint?, Never>) in
                let finish: @Sendable (NWEndpoint?) -> Void = { remote in
                    let first = finished.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    connection.cancel()
                    continuation.resume(returning: remote)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(connection.currentPath?.remoteEndpoint)
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
