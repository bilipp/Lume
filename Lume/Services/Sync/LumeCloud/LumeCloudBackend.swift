import Foundation
import LumeCloudKit
import OSLog
import SwiftData

/// Lume Cloud: syncs `LumeCloudUserData.store` with the Lume Cloud server
/// through `LumeCloudTransport`, and runs the account flows (create, pairing,
/// devices, recovery, leave, delete) in its extensions.
///
/// Holds the identity in memory once joined; the keychain (`LumeCloudKeyStore`)
/// is the durable copy. Nothing of the identity, the device id, pairing codes or
/// payloads is ever logged.
@MainActor
final class LumeCloudBackend: SyncBackend {
    let kind: SyncBackendKind? = .lumecloud
    let container: ModelContainer
    /// This build's server (`LumeCloudConfig.serverURL`).
    let serverURL: URL
    /// `-ui-testing` and previews: never touches the network or the keychain.
    let isInert: Bool
    let settings: LumeCloudSettings
    let keyStore: LumeCloudKeyStore
    let defaults: UserDefaults
    let makeClient: LumeCloudClientFactory
    let pairingPollInterval: Duration
    let eventBackoff: LumeCloudEventListener.Backoff
    let now: @Sendable () -> Date

    private(set) var identity: LumeCloudIdentity?
    private(set) var transport: LumeCloudTransport?
    /// Whether the last keychain read was refused (locked before first unlock),
    /// so the next pass reads it again instead of treating the device as unjoined.
    private var identityReadFailed = false
    private weak var host: (any SyncBackendHost)?
    /// When the last pull started; a foreground return pulls again once
    /// `foregroundPullInterval` has passed.
    private var lastPullAt: Date?
    /// Identifies the running push, so progress hops that land after it finished
    /// can't overwrite the final state.
    private var pushGeneration = 0
    private var activePush: Int?
    private var hasSettledInitialSync = false
    /// Whether the scene is active, so the socket may be open.
    private var listensForEvents = false
    /// The socket of the current transport; only while attached, joined and listening.
    private(set) var eventListener: LumeCloudEventListener?
    /// A socket poke pulled rows the engine hasn't reconciled yet.
    private var hasUnreconciledPull = false

    /// Called when the account ended under this device (remote deletion or this
    /// device's revocation). The identity is already dropped; the owner switches
    /// the device's backend.
    var onAccountEnded: ((LumeCloudAccountEnd) -> Void)?

    /// Nothing tells this device about remote changes while the socket is down,
    /// so a foreground return pulls when the last pull is at least this old.
    static let foregroundPullInterval: TimeInterval = 30
    /// How long a poke's pull stands in for the pull of the pass it requested.
    static let pokePullReuseInterval: TimeInterval = 5

    init(
        container: ModelContainer,
        serverURL: URL = LumeCloudConfig.serverURL,
        defaults: UserDefaults = .standard,
        keyStore: LumeCloudKeyStore = LumeCloudKeyStore(),
        isInert: Bool = LumeApp.isAutomatedRun,
        pairingPollInterval: Duration = .seconds(2),
        eventBackoff: LumeCloudEventListener.Backoff = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        makeClient: LumeCloudClientFactory? = nil
    ) {
        self.container = container
        self.serverURL = serverURL
        self.defaults = defaults
        settings = LumeCloudSettings(defaults: defaults)
        self.keyStore = keyStore
        self.isInert = isInert
        self.pairingPollInterval = pairingPollInterval
        self.eventBackoff = eventBackoff
        self.now = now
        self.makeClient = makeClient ?? LiveLumeCloudAccountAPI.factory(serverURL: serverURL)
        guard !isInert else { return }
        loadIdentity()
    }

    /// The backend over the on-disk Lume Cloud store; in-memory while inert, so
    /// UI tests never create the file.
    static func makeDefault() throws -> LumeCloudBackend {
        let inert = LumeApp.isAutomatedRun
        return try LumeCloudBackend(container: LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: inert), isInert: inert)
    }

    var mirrorContainer: ModelContainer? {
        container
    }

    /// Joined and able to sync.
    var isJoined: Bool {
        transport != nil
    }

    private var idleState: LumeCloudSyncState {
        isJoined ? .joined : .notJoined
    }

    /// The coordinator's active backend.
    var isAttached: Bool {
        host != nil
    }

    var waitsForInitialSync: Bool {
        !isInert && identity != nil
    }

    var hasPendingChanges: Bool {
        guard isJoined else { return false }
        guard !hasUnreconciledPull, let lastPullAt else { return true }
        return now().timeIntervalSince(lastPullAt) >= Self.foregroundPullInterval
    }

    // MARK: SyncBackend

    func attach(to host: any SyncBackendHost) {
        self.host = host
        host.status.lumeCloud = idleState
        updateEventListener()
    }

    func start() async {
        reloadIdentityIfNeeded()
        guard let host else { return }
        guard isJoined else {
            settleInitialSync()
            return
        }
        host.reconcile(reason: .launch, debounced: true)
        Task { [weak self] in
            try? await Task.sleep(for: CloudSyncCoordinator.initialSyncTimeout)
            self?.settleInitialSync()
        }
    }

    func refreshStatus() async {
        reloadIdentityIfNeeded()
    }

    /// Whether the mirror store was lost since it last synced; its bookkeeping
    /// is then reset so the next pull refills it (`LumeCloudTransport.recoverLostMirror`).
    func recoverLostMirror() async -> Bool {
        reloadIdentityIfNeeded()
        return await transport?.recoverLostMirror() ?? false
    }

    /// The transport posts `.lumeSyncMirrorDidChange` itself when the pull
    /// changed a row.
    func pull() async throws {
        reloadIdentityIfNeeded()
        guard let transport else { return }
        if hasUnreconciledPull, let lastPullAt, now().timeIntervalSince(lastPullAt) < Self.pokePullReuseInterval {
            // The pass a poke requested: the poke's own pull is still current.
            hasUnreconciledPull = false
            settleInitialSync()
            return
        }
        lastPullAt = now()
        hasUnreconciledPull = false
        setState(.syncing)
        defer { settleInitialSync() }
        do {
            try await transport.pull()
        } catch {
            handleSyncError(error)
            throw error
        }
    }

    func push() async throws {
        guard let transport else { return }
        pushGeneration += 1
        let generation = pushGeneration
        activePush = generation
        defer { activePush = nil }
        do {
            try await transport.push { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, activePush == generation else { return }
                    setState(.uploading(completed: progress.completed, total: progress.total))
                }
            }
            setState(.joined)
            host?.status.lastError = nil
        } catch {
            handleSyncError(error)
            throw error
        }
    }

    func stop() {
        host = nil
        updateEventListener()
    }

    func observeAccountEnd(_ handler: @escaping (LumeCloudAccountEnd) -> Void) {
        onAccountEnded = handler
    }

    // MARK: Identity

    private func loadIdentity() {
        switch keyStore.load() {
        case let .identity(stored):
            identityReadFailed = false
            do {
                try installTransport(for: stored)
            } catch {
                Logger.sync.error("Lume Cloud identity is unusable: the stored root key is malformed")
            }
        case .notSet:
            identityReadFailed = false
        case .unavailable:
            identityReadFailed = true
        }
    }

    private func reloadIdentityIfNeeded() {
        guard !isInert, identity == nil, identityReadFailed else { return }
        loadIdentity()
        if isJoined {
            setState(.joined)
        }
    }

    /// Credentials for the account `keys` derive, on this device.
    func credentials(keys: LumeCloudKeys, deviceID: UUID? = nil) -> LumeCloudClient.Credentials {
        LumeCloudClient.Credentials(keys: keys, deviceID: deviceID ?? settings.deviceID)
    }

    private func installTransport(for identity: LumeCloudIdentity) throws {
        eventListener?.stop()
        eventListener = nil
        let keys = try LumeCloudKeys(rootKey: identity.rootKey)
        transport = try LumeCloudTransport(
            client: makeClient(credentials(keys: keys)),
            container: container,
            rootKey: identity.rootKey,
            accountId: identity.accountId,
            now: now
        )
        self.identity = identity
        lastPullAt = nil
        updateEventListener()
    }

    /// Makes `identity` this backend's account. With `wipingStore`, the Lume
    /// Cloud mirror, its bookkeeping and the `.lumecloud` shadow start empty, so
    /// the next pull refills them from the server (a join never reuses another
    /// session's local state). The owner swaps the engine afterwards, so it
    /// re-reads the emptied shadow.
    func activate(_ identity: LumeCloudIdentity, wipingStore: Bool) async throws {
        let previous = transport
        transport = nil
        self.identity = nil
        updateEventListener()
        if let previous {
            // Let an in-flight pull or push finish before the store changes under it.
            _ = try? await previous.serialized { _ in }
        }
        if wipingStore {
            try await Self.wipeStore(container)
            CloudSyncShadow(defaults: defaults, namespace: .lumecloud).resetAll()
        } else {
            try await Self.clearHistoryToken(container)
        }
        try installTransport(for: identity)
        setState(.joined)
    }

    /// Drops the in-memory identity and transport. The keychain is the caller's call.
    func deactivate(state: LumeCloudSyncState) {
        transport = nil
        identity = nil
        lastPullAt = nil
        hasUnreconciledPull = false
        updateEventListener()
        setState(state)
    }

    /// Empties the Lume Cloud mirror and its bookkeeping (cursor back to 0) so
    /// the next pull refills them from the server: a switch into Lume Cloud
    /// never reuses an earlier session's sync state. Waits for an in-flight
    /// pull or push first.
    func prepareMirrorForAttach() async throws {
        if let transport {
            let container = container
            try await transport.serialized { _ in try await Self.wipeStore(container) }
        } else {
            try await Self.wipeStore(container)
        }
        lastPullAt = nil
    }

    /// Makes the next push diff every mirror row: rows written while another
    /// backend was active are in the store's history, but the token predates
    /// the switch. `wipeStore` drops the token with the sync meta.
    private nonisolated static func clearHistoryToken(_ container: ModelContainer) async throws {
        try await Task.detached {
            let context = LumeCloudTransport.makeContext(in: container)
            for meta in try context.fetch(FetchDescriptor<LumeCloudSyncMeta>()) where meta.historyToken != nil {
                meta.historyToken = nil
            }
            if context.hasChanges {
                try context.save()
            }
        }.value
    }

    private nonisolated static func wipeStore(_ container: ModelContainer) async throws {
        try await Task.detached {
            let context = LumeCloudTransport.makeContext(in: container)
            func wipe<Model: PersistentModel>(_: Model.Type) throws {
                try context.delete(model: Model.self)
            }
            for modelType in LumeCloudPayloadCodec.mappableModels {
                try wipe(modelType)
            }
            try wipe(LumeCloudRecordState.self)
            try wipe(LumeCloudSyncMeta.self)
            try context.save()
        }.value
    }

    // MARK: Live updates

    /// The scene became active (`true`) or left it. The socket only runs while
    /// active, attached and joined.
    func setListensForEvents(_ listens: Bool) {
        listensForEvents = listens
        updateEventListener()
    }

    private func updateEventListener() {
        guard !isInert, listensForEvents, host != nil, let transport else {
            eventListener?.stop()
            eventListener = nil
            return
        }
        guard eventListener == nil else { return }
        let listener = LumeCloudEventListener(
            backoff: eventBackoff,
            connect: { transport.events() },
            onSeq: { [weak self] seq in await self?.pullForEvent(seq: seq, on: transport) },
            probe: { [weak self] in await self?.probeRefusedSocket(on: transport) ?? .stop }
        )
        eventListener = listener
        listener.start()
    }

    /// A poke: pull when the feed moved past the stored cursor, and request a
    /// pass only when that pull changed the mirror. The echo of this device's
    /// own push changes nothing and costs no reconcile.
    private func pullForEvent(seq: Int, on poked: LumeCloudTransport) async {
        guard poked === transport else { return }
        do {
            guard let result = try await poked.pull(ifBehind: seq), poked === transport else { return }
            lastPullAt = now()
            guard result.mirrorChanged else { return }
            hasUnreconciledPull = true
            host?.reconcile(reason: .remoteChange, debounced: true)
        } catch {
            guard poked === transport else { return }
            handleSyncError(error)
        }
    }

    /// The socket upgrade was refused: `/changes` names the reason, and a
    /// deleted account or a revoked device ends the membership as a pass would.
    private func probeRefusedSocket(on poked: LumeCloudTransport) async -> LumeCloudEventListener.ProbeVerdict {
        do {
            try await poked.probeAccess()
            return .reconnect
        } catch {
            guard poked === transport else { return .stop }
            handleSyncError(error)
            if case LumeCloudError.badAuth = error {
                return .stop
            }
            return isJoined ? .reconnect : .stop
        }
    }

    // MARK: Status

    func setState(_ state: LumeCloudSyncState) {
        host?.status.lumeCloud = state
    }

    private func settleInitialSync() {
        guard !hasSettledInitialSync, let host else { return }
        hasSettledInitialSync = true
        host.backendDidSettleInitialSync()
    }

    /// Maps a failed pass to the status; a deleted account or a revoked device
    /// ends this device's membership.
    func handleSyncError(_ error: any Error) {
        host?.status.lastError = LumeCloudErrorDescription.message(for: error)
        guard let cloudError = error as? LumeCloudError else {
            setState(idleState)
            return
        }
        switch cloudError {
        case .accountDeleted:
            endAccount(.accountDeleted)
        case .deviceRevoked:
            endAccount(.deviceRevoked)
        default:
            setState(LumeCloudSyncState(error: cloudError) ?? idleState)
        }
    }

    /// The server ended this device's membership. A deleted account takes the
    /// shared keychain identity with it; a revoked device only gives up its own
    /// device id (the identity is shared with the user's other Apple devices).
    func endAccount(_ reason: LumeCloudAccountEnd) {
        switch reason {
        case .accountDeleted:
            keyStore.clear()
            Logger.sync.notice("Lume Cloud account was deleted: leaving")
            deactivate(state: .accountDeleted)
        case .deviceRevoked:
            // The synchronizable identity stays: it belongs to the whole Apple
            // ID, the user's other Apple devices are still members, and keeping
            // it lets this device rejoin without a code. The device id has to
            // go, because the server never registers a revoked id again.
            settings.rotateDeviceID()
            Logger.sync.notice("This device was removed from Lume Cloud: leaving")
            deactivate(state: .revoked)
        }
        onAccountEnded?(reason)
    }
}
