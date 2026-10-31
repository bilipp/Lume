import Foundation
import LumeCloudKit
import OSLog
import SwiftData

/// What one pull did. Counts only: payloads never leave the transport.
nonisolated struct LumeCloudPullResult: Equatable {
    /// The stored `/changes` cursor after the pull.
    var nextSeq: Int
    /// Whether any mirror row was inserted, changed or deleted.
    var mirrorChanged: Bool
    /// Records this build can't read (an unknown envelope version, a payload
    /// that doesn't decode, or a `rid` its key doesn't derive), held in the
    /// bookkeeping for a later build. Counts the ones earlier pulls held and
    /// this pull still couldn't read, too.
    var skippedRecords: Int
}

/// Moves the Lume Cloud mirror store to and from the server (PROTOCOL.md §6).
///
/// Owns its own background `ModelContext` per pass, never the main context, so
/// a pull during playback can't hitch the player. Every write lands in the mirror
/// store; `CloudSyncEngine` reconciles the catalog against it afterwards.
actor LumeCloudTransport {
    let accountId: String
    /// The server `client` talks to, as `LumeCloudConfig.comparable`: the
    /// bookkeeping is reset when it was written against another one.
    let serverURL: String
    let client: any LumeCloudSyncing
    let container: ModelContainer
    let keys: LumeCloudKeys
    let now: @Sendable () -> Date
    /// The previous pull, push or bookkeeping write. Each one awaits it: the
    /// bookkeeping read before a network round trip must still be current when
    /// the results are applied.
    private var lastOperation: Task<Void, Never>?
    /// No request goes out before this moment after a 429.
    var rateLimitedUntil: Date?
    var consecutiveRateLimits = 0
    /// When the server last answered a push with 507. Pushes wait until
    /// `quotaRetryInterval` has passed or a deletion frees space; pulls go on.
    var quotaExceededAt: Date?
    /// The canonical bytes the server rejected with 413, per record. The record
    /// isn't sent again until its payload changes.
    var oversizedRecords: [String: Data] = [:]
    /// Record types this transport handles as unknown, the way a build that
    /// predates them would. Empty in the app; tests use it to stand for an
    /// older build.
    let unreadableRecordTypes: Set<String>
    /// Rows another writer deleted on purpose and the next pass reports; a
    /// repair never restores one of them.
    let deletionLog: SyncMirrorDeletionLog
    /// `LumeCloudPayloadCodec.encoded` calls a push made to diff mirror rows.
    /// Read by tests.
    var upsertEncodeCount = 0

    /// The longest key list a fetch looks up by key; a longer one reads every row.
    nonisolated static let maxKeyedFetch = 500

    /// The `ModelContext.author` of every transport write, so a history reader
    /// can tell sync writes from the app's own.
    nonisolated static let contextAuthor = "LumeCloudTransport"

    /// `container` is the Lume Cloud mirror (`LumeApp.makeLumeCloudContainer`),
    /// which carries the bookkeeping models too. `serverURL` is the server
    /// `client` talks to.
    init(
        client: any LumeCloudSyncing,
        container: ModelContainer,
        rootKey: Data,
        accountId: String,
        serverURL: URL = LumeCloudConfig.defaultURL,
        now: @escaping @Sendable () -> Date = { Date() },
        unreadableRecordTypes: Set<String> = [],
        deletionLog: SyncMirrorDeletionLog = .shared
    ) throws {
        self.client = client
        self.container = container
        keys = try LumeCloudKeys(rootKey: rootKey)
        self.accountId = accountId
        self.serverURL = LumeCloudConfig.comparable(serverURL)
        self.now = now
        self.unreadableRecordTypes = unreadableRecordTypes
        self.deletionLog = deletionLog
    }

    /// Runs `operation` once every earlier operation has finished, so no two
    /// passes interleave across their network awaits.
    func serialized<Result: Sendable>(
        _ operation: @escaping @Sendable (isolated LumeCloudTransport) async throws -> Result
    ) async throws -> Result {
        let previous = lastOperation
        let task = Task {
            await previous?.value
            return try await operation(self)
        }
        lastOperation = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Pull

    /// Pulls every change since the stored cursor, merges it into the mirror and
    /// posts `.lumeSyncMirrorDidChange` when a row changed.
    @discardableResult
    func pull() async throws -> LumeCloudPullResult {
        try await serialized { transport in try await transport.performPull() }
    }

    /// Pulls only when the stored cursor is behind `seq` (a socket poke);
    /// `nil` when it already covers it.
    func pull(ifBehind seq: Int) async throws -> LumeCloudPullResult? {
        try await serialized { transport in
            guard try transport.storedCursor() < seq else { return nil }
            return try await transport.performPull()
        }
    }

    /// The stored `/changes` cursor; 0 before the first pull of this account
    /// on this server.
    func storedCursor() throws -> Int {
        let context = makeContext()
        guard let meta = try context.fetch(FetchDescriptor<LumeCloudSyncMeta>()).first,
              meta.accountId == accountId, !isFromAnotherServer(meta)
        else { return 0 }
        return meta.nextSeq
    }

    /// Whether `meta` was written against another server's feed. Bookkeeping
    /// from before the server was recorded counts as this server's.
    func isFromAnotherServer(_ meta: LumeCloudSyncMeta) -> Bool {
        !meta.serverURL.isEmpty && meta.serverURL != serverURL
    }

    private func performPull() async throws -> LumeCloudPullResult {
        let interval = Perf.begin(.lumeCloudPull)
        defer { Perf.end(interval) }
        let context = makeContext()
        let meta = try preparedSyncMeta(in: context)
        let since = meta.nextSeq
        // Saved before the request: the repair is local, and an offline pull
        // still owes the engine the restored rows.
        let restored = try restoreUnrecordedRemovals(in: context)
        if context.hasChanges {
            try context.save()
        }
        if restored > 0 {
            await postMirrorDidChange()
        }

        let page: ChangesPage
        let isSnapshot: Bool
        do {
            page = try await request { try await client.allChanges(since: since, limit: LumeCloudAPI.maxChangesLimit) }
            isSnapshot = since == 0
        } catch LumeCloudError.resyncRequired {
            // PROTOCOL.md §6.3: the snapshot drops every synced record it no
            // longer lists, unless it changed here since it last synced.
            Logger.sync.notice("Lume Cloud cursor is past the tombstone horizon: full resync")
            page = try await request { try await client.allChanges(since: 0, limit: LumeCloudAPI.maxChangesLimit) }
            isSnapshot = true
            update(meta, \.historyToken, to: nil)
        }

        var result = try Perf.measure(.lumeCloudMerge) {
            try apply(page, isSnapshot: isSnapshot, meta: meta, in: context)
        }
        let records = page.records.count
        let skipped = result.skippedRecords
        Logger.sync.info("Lume Cloud pull: \(records) records, \(skipped) skipped")
        if result.mirrorChanged {
            await postMirrorDidChange()
        }
        result.mirrorChanged = result.mirrorChanged || restored > 0
        return result
    }

    func postMirrorDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .lumeSyncMirrorDidChange, object: nil)
        }
    }

    /// The account's sync meta, with its bookkeeping reset when it belongs to
    /// another account, to another server's feed, or when the mirror was lost
    /// (`mirrorWasLost`, PROTOCOL.md §6.4): pulling from 0 then refills the
    /// mirror instead of a later push reading the empty mirror as deletions.
    /// `mirrorLost` is a `mirrorWasLost` result the caller already has.
    func preparedSyncMeta(in context: ModelContext, mirrorLost: Bool? = nil) throws -> LumeCloudSyncMeta {
        let meta: LumeCloudSyncMeta
        if let existing = try context.fetch(FetchDescriptor<LumeCloudSyncMeta>()).first {
            meta = existing
        } else {
            meta = LumeCloudSyncMeta(accountId: accountId)
            context.insert(meta)
        }
        if meta.accountId != accountId {
            try resetBookkeeping(meta, keepingHeldRecords: false, in: context)
            meta.accountId = accountId
        } else if isFromAnotherServer(meta) {
            // The same account on another server: its seqs and versions are
            // another feed's, and a cursor ahead of this feed's head would skip
            // every record up to it. The mirror is still this account's data.
            Logger.sync.notice("Lume Cloud server changed: pulling everything again")
            try resetBookkeeping(meta, keepingHeldRecords: true, in: context)
        } else if try mirrorLost ?? mirrorWasLost(in: context) {
            try resetBookkeeping(meta, keepingHeldRecords: true, in: context)
        }
        update(meta, \.serverURL, to: serverURL)
        return meta
    }

    /// Resets the bookkeeping, saved at once, when the mirror was lost
    /// (`mirrorWasLost`, PROTOCOL.md §6.4), so the next pull starts from 0
    /// even if this pass can't reach the server. True when it did: the caller
    /// must then drop its reconcile baseline too, or the empty mirror reads as
    /// a deletion of every local item.
    func recoverLostMirror() async -> Bool {
        do {
            return try await serialized { transport in
                let context = transport.makeContext()
                guard try transport.mirrorWasLost(in: context) else { return false }
                _ = try transport.preparedSyncMeta(in: context, mirrorLost: true)
                try context.save()
                Logger.sync.notice("Lume Cloud mirror came up empty after syncing: pulling everything again")
                return true
            }
        } catch {
            Logger.sync.error("Lume Cloud mirror check failed: \(error)")
            return false
        }
    }

    /// Drops the bookkeeping, the cursor and the push history token.
    /// `keepingHeldRecords` keeps each held record, reset to never applied: the
    /// snapshot pull that follows drops it if the server no longer lists it. It
    /// keeps unpushed user deletions as they are, so the pull can't revive them.
    /// Another account's held records never open under these keys, so they go.
    func resetBookkeeping(_ meta: LumeCloudSyncMeta, keepingHeldRecords: Bool, in context: ModelContext) throws {
        for state in try context.fetch(FetchDescriptor<LumeCloudRecordState>()) {
            if keepingHeldRecords, state.isDeletionPending, state.lastSyncedPayload != nil, !state.isUndecodable {
                continue
            }
            guard keepingHeldRecords, state.isUndecodable else {
                context.delete(state)
                continue
            }
            update(state, \.version, to: 0)
            update(state, \.lastSyncedPayload, to: nil)
            update(state, \.isDirty, to: false)
            update(state, \.isDeletionPending, to: false)
        }
        update(meta, \.nextSeq, to: 0)
        update(meta, \.historyToken, to: nil)
    }

    /// An empty mirror although records were synced, with no recorded deletion
    /// to explain it: a lost or recreated store. A mirror the user's own
    /// deletions emptied leaves every synced record pending deletion; it is
    /// ready, and its tombstones push without a reset.
    func mirrorWasLost(in context: ModelContext) throws -> Bool {
        try mirrorIsEmpty(in: context) && hasUnexplainedSyncedRecords(in: context)
    }

    private func mirrorIsEmpty(in context: ModelContext) throws -> Bool {
        func count<Model: PersistentModel>(_: Model.Type) throws -> Int {
            try context.fetchCount(FetchDescriptor<Model>())
        }
        for modelType in LumeCloudPayloadCodec.mappableModels where try count(modelType) > 0 {
            return false
        }
        return true
    }

    /// Whether a known-type record has synced and isn't pending deletion.
    private func hasUnexplainedSyncedRecords(in context: ModelContext) throws -> Bool {
        // A closure, not `\.lumeCloudType`: a key path on the existential metatype
        // crashes SILGen (Swift 6.3).
        let knownTypes = LumeCloudPayloadCodec.mappableModels.map { modelType in modelType.lumeCloudType }
        var descriptor = FetchDescriptor<LumeCloudRecordState>(
            predicate: #Predicate { $0.lastSyncedPayload != nil && !$0.isDeletionPending && knownTypes.contains($0.type) }
        )
        descriptor.fetchLimit = 1
        return try context.fetchCount(descriptor) > 0
    }

    // MARK: Applying a page

    /// One server record, decrypted. `payload` and `bytes` are nil for a
    /// tombstone; `bytes` is the payload's canonical encoding and `ciphertext`
    /// the envelope it came from.
    nonisolated struct PulledRecord {
        var rid: String
        var version: Int
        var key: String
        var type: String
        var payload: LumeCloudPayload?
        var bytes: Data?
        var seq = 0
        var ciphertext: String?

        var remote: RemoteRecord {
            RemoteRecord(rid: rid, version: version, seq: seq, deleted: ciphertext == nil, ciphertext: ciphertext, updatedAt: 0)
        }
    }

    private func apply(
        _ page: ChangesPage,
        isSnapshot: Bool,
        meta: LumeCloudSyncMeta,
        in context: ModelContext
    ) throws -> LumeCloudPullResult {
        // `allChanges` can list a record twice when it changed mid-walk; the later
        // entry is the current one.
        var latest: [String: RemoteRecord] = [:]
        for record in page.records {
            latest[record.rid] = record
        }
        // A snapshot reads every record to find the ones it no longer lists.
        let stateFetch: FetchDescriptor<LumeCloudRecordState>
        if isSnapshot || latest.count > Self.maxKeyedFetch {
            stateFetch = FetchDescriptor()
        } else {
            let rids = Array(latest.keys)
            stateFetch = FetchDescriptor(predicate: #Predicate { rids.contains($0.rid) || $0.undecodableCiphertext != nil })
        }
        var states = try Dictionary(
            context.fetch(stateFetch).map { ($0.rid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let deletions: [String: [PulledRecord]] = isSnapshot ? snapshotDeletions(listed: latest, states: states) : [:]
        // Held records go first, so a newer version in the page replaces them.
        // One this build can read now applies like any pulled record.
        var pending = Dictionary(
            states.values.compactMap(heldRecord).map { ($0.rid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        pending.merge(latest) { _, pulled in pulled }

        let outcome = try mergeRemote(pending.values, startingWith: deletions, states: &states, in: context)

        update(meta, \.nextSeq, to: page.nextSeq)
        if context.hasChanges {
            try context.save()
        }
        return LumeCloudPullResult(nextSeq: meta.nextSeq, mirrorChanged: outcome.changed, skippedRecords: outcome.skipped)
    }

    /// Opens each server record and merges it into the mirror with `groups`,
    /// holding the ones this build can't read. `skipped` counts those held.
    func mergeRemote(
        _ records: some Sequence<RemoteRecord>,
        startingWith groups: [String: [PulledRecord]] = [:],
        states: inout [String: LumeCloudRecordState],
        in context: ModelContext
    ) throws -> (changed: Bool, skipped: Int) {
        var groups = groups
        var skipped = 0
        for record in records {
            switch opened(record, state: states[record.rid]) {
            case let .apply(pulled): groups[pulled.type, default: []].append(pulled)
            case .nothing: continue
            case .unreadable:
                hold(record, key: nil, type: nil, states: &states, in: context)
                skipped += 1
            }
        }

        var changed = false
        for (type, records) in groups {
            guard let modelType = mergingModelType(forRecordType: type) else {
                keepUnknown(records, states: &states, in: context)
                continue
            }
            let outcome = try merge(records, as: modelType, states: &states, in: context)
            changed = changed || outcome.changed
            skipped += outcome.skipped
        }
        return (changed, skipped)
    }

    /// A snapshot (`since == 0`) lists live records only, so a synced record it
    /// leaves out was deleted on the server, and so was a held version of it.
    /// Returns a tombstone per such synced record, by type.
    private func snapshotDeletions(
        listed: [String: RemoteRecord],
        states: [String: LumeCloudRecordState]
    ) -> [String: [PulledRecord]] {
        var groups: [String: [PulledRecord]] = [:]
        for (rid, state) in states where listed[rid] == nil {
            release(state)
            guard state.lastSyncedPayload != nil else { continue }
            groups[state.type, default: []].append(PulledRecord(
                rid: rid, version: state.version, key: state.logicalKey, type: state.type
            ))
        }
        return groups
    }

    nonisolated enum OpenedRecord {
        case apply(PulledRecord)
        /// A tombstone of a record this device never saw.
        case nothing
        /// The caller holds it (PROTOCOL.md §2.4).
        case unreadable
    }

    /// Decrypts `record`.
    func opened(_ record: RemoteRecord, state: LumeCloudRecordState?) -> OpenedRecord {
        guard !record.deleted, let ciphertext = record.ciphertext else {
            guard let state else { return .nothing }
            return .apply(PulledRecord(
                rid: record.rid, version: record.version, key: state.logicalKey, type: state.type, seq: record.seq
            ))
        }
        do {
            let payload = try keys.openPayload(ciphertext, rid: record.rid)
            // The logical key must derive the record's `rid`, or a push from this
            // bookkeeping would write a different record.
            guard keys.recordID(for: payload.key) == record.rid else { return .unreadable }
            return try .apply(PulledRecord(
                rid: record.rid, version: record.version, key: payload.key, type: payload.type,
                payload: payload, bytes: payload.encoded(), seq: record.seq, ciphertext: ciphertext
            ))
        } catch {
            return .unreadable
        }
    }

    /// The conflict-merging model a record `type` maps to; nil for a type this
    /// build doesn't know.
    func mergingModelType(forRecordType type: String) -> (any LumeCloudConflictMerging.Type)? {
        guard !unreadableRecordTypes.contains(type) else { return nil }
        return LumeCloudPayloadCodec.mergingModelType(forRecordType: type)
    }

    /// Records of a type this build doesn't know: each is held, kept forever
    /// (PROTOCOL.md §2.5) until a build that knows the type applies it. A
    /// tombstone ends the hold.
    func keepUnknown(_ records: [PulledRecord], states: inout [String: LumeCloudRecordState], in context: ModelContext) {
        for record in records {
            guard record.payload == nil else {
                hold(record.remote, key: record.key, type: record.type, states: &states, in: context)
                continue
            }
            let state = recordState(rid: record.rid, key: record.key, type: record.type, states: &states, in: context)
            update(state, \.version, to: record.version)
            update(state, \.lastSyncedPayload, to: nil)
            update(state, \.isDirty, to: false)
            release(state)
        }
    }

    /// Keeps a server version this build can't apply, envelope and all, so a
    /// later pull can apply it. `key` and `type` name a record first seen here.
    func hold(
        _ record: RemoteRecord,
        key: String?,
        type: String?,
        states: inout [String: LumeCloudRecordState],
        in context: ModelContext
    ) {
        let state = recordState(rid: record.rid, key: key ?? "", type: type ?? "", states: &states, in: context)
        update(state, \.undecodableCiphertext, to: record.ciphertext)
        update(state, \.undecodableVersion, to: record.version)
        update(state, \.undecodableSeq, to: record.seq)
    }

    /// Ends the hold on `state`: a version that supersedes it was applied.
    func release(_ state: LumeCloudRecordState) {
        guard state.isUndecodable else { return }
        update(state, \.undecodableCiphertext, to: nil)
        update(state, \.undecodableVersion, to: 0)
        update(state, \.undecodableSeq, to: 0)
    }

    private func heldRecord(_ state: LumeCloudRecordState) -> RemoteRecord? {
        guard let ciphertext = state.undecodableCiphertext else { return nil }
        return RemoteRecord(
            rid: state.rid, version: state.undecodableVersion, seq: state.undecodableSeq,
            deleted: false, ciphertext: ciphertext, updatedAt: 0
        )
    }

    /// The bookkeeping for `rid`, inserted when there is none yet.
    func recordState(
        rid: String,
        key: String,
        type: String,
        states: inout [String: LumeCloudRecordState],
        in context: ModelContext
    ) -> LumeCloudRecordState {
        if let state = states[rid] {
            return state
        }
        let state = LumeCloudRecordState(rid: rid, logicalKey: key, type: type)
        context.insert(state)
        states[rid] = state
        return state
    }
}

// MARK: - Store writes

extension LumeCloudTransport {
    /// The mirror rows of `Model` under `keys`, and possibly others. Reads every
    /// row when `Model` has no keyed lookup or `keys` is too long for one.
    func mirrorRows<Model: LumeCloudPayloadMappable>(
        _: Model.Type,
        withKeys keys: Set<String>,
        in context: ModelContext
    ) throws -> [Model] {
        let keyed = keys.count <= Self.maxKeyedFetch ? Model.lumeCloudRowsDescriptor(forKeys: keys) : nil
        return try context.fetch(keyed ?? FetchDescriptor<Model>())
    }

    /// A fresh background context on the mirror, tagged with `contextAuthor`.
    func makeContext() -> ModelContext {
        Self.makeContext(in: container)
    }

    /// A fresh background context on `container`, tagged with `contextAuthor`.
    nonisolated static func makeContext(in container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.author = contextAuthor
        context.autosaveEnabled = false
        return context
    }

    /// Assigns `value` only when it differs: an equal assignment still marks the
    /// row changed, so an unchanged pass would rewrite it on save.
    func update<Model: PersistentModel, Value: Equatable>(
        _ model: Model,
        _ keyPath: ReferenceWritableKeyPath<Model, Value>,
        to value: Value
    ) {
        if model[keyPath: keyPath] != value {
            model[keyPath: keyPath] = value
        }
    }
}
