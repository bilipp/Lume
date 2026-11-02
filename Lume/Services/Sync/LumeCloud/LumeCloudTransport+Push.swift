import Foundation
import LumeCloudKit
import OSLog
import SwiftData

/// How far one push round that spans several requests has got. The coordinator
/// maps it to `CloudSyncStatus.uploading`.
nonisolated struct LumeCloudUploadProgress: Equatable {
    var completed: Int
    var total: Int
}

/// What one push did. Counts only: payloads never leave the transport.
nonisolated struct LumeCloudPushResult: Equatable {
    /// Records the server applied, tombstones included.
    var pushedRecords = 0
    /// Conflict results, each merged into the mirror like a pulled record.
    var conflicts = 0
    /// Push rounds sent: the first one plus one per conflict retry.
    var rounds = 0
    /// Records left out of this pass: over the record size limit, or held
    /// because the server has a version this build can't read.
    var skippedRecords = 0
    /// Whether collapsing duplicate rows or merging a conflict changed the mirror.
    var mirrorChanged = false
    /// Whether the server's feed turned out to be behind the stored cursor —
    /// the cursor came from another feed (an account moved between servers, a
    /// restored backup) — so the bookkeeping was reset and the next pull
    /// starts over from 0. The caller owes a pass for that pull.
    var feedRewound = false
}

/// One record of a push request, with the canonical bytes it carries (nil for a
/// tombstone) so a success can store them as the new merge base.
nonisolated struct LumeCloudOutgoingRecord {
    var record: PushRecord
    var bytes: Data?
}

extension LumeCloudTransport {
    /// The first push plus conflict retries (PROTOCOL.md §6.2). A record still
    /// conflicting after the last round waits for the next pass.
    nonisolated static let maxPushRounds = 3
    /// The request body cap of PROTOCOL.md §4.4; the Kit only names the record cap.
    nonisolated static let maxPushBodyBytes = 4 * 1024 * 1024
    /// Version byte, nonce and GCM tag around the plaintext (PROTOCOL.md §2.4).
    nonisolated static let envelopeOverhead = 1 + 12 + 16
    /// JSON around one record's ciphertext in a push body, rounded up.
    nonisolated static let pushRecordOverhead = 128
    nonisolated static let pushBodyOverhead = 32
    /// Requests whose results one bookkeeping save covers; a crash loses at
    /// most these, which the next pass diffs again.
    nonisolated static let requestsPerSave = 10

    /// Mutable state of one push pass.
    private nonisolated struct PushPass {
        var scope: LumeCloudPushScope
        /// The bookkeeping this pass has read: every record for a full diff,
        /// else the dirty ones and those of the rows it diffs.
        var states: [String: LumeCloudRecordState]
        /// Records not retried in this pass.
        /// The stored `/changes` cursor this pass started from.
        let cursor: Int
        var excluded: Set<String> = []
        var result = LumeCloudPushResult()
        /// Set when a response proved the server's feed behind `cursor`
        /// (`noteServerSeqs`).
        var cursorAheadOfFeed = false

        mutating func skip(_ rid: String) {
            excluded.insert(rid)
            result.skippedRecords += 1
        }
    }

    // MARK: Push

    /// Pushes every mirror row whose canonical payload differs from its last
    /// synced bytes, plus a tombstone per recorded deletion, merging conflicts
    /// and retrying up to `maxPushRounds`. Once a push has stored a history
    /// token, the next one diffs only the rows other writers changed since,
    /// plus dirty records. `progress` reports only rounds that span more than
    /// one request.
    @discardableResult
    func push(progress: (@Sendable (LumeCloudUploadProgress) -> Void)? = nil) async throws -> LumeCloudPushResult {
        try await serialized { transport in try await transport.performPush(progress: progress) }
    }

    private func performPush(progress: (@Sendable (LumeCloudUploadProgress) -> Void)?) async throws -> LumeCloudPushResult {
        let interval = Perf.begin(.lumeCloudPush)
        defer { Perf.end(interval) }
        try throwIfRateLimited()
        try throwIfQuotaExceeded()
        let context = makeContext()
        let mirrorLost: Bool
        do {
            mirrorLost = try mirrorWasLost(in: context)
        } catch {
            // Mid-detach or corrupt: the mirror can't stand for this device's data.
            Logger.sync.error("Lume Cloud push skipped: the mirror store is unreadable")
            return LumeCloudPushResult()
        }
        let meta = try preparedSyncMeta(in: context, mirrorLost: mirrorLost)
        // PROTOCOL.md §6.4: an emptied mirror never pushes. The reset bookkeeping
        // makes the next pull start over from 0 and refill it.
        guard !mirrorLost else {
            try context.save()
            Logger.sync.notice("Lume Cloud push skipped: the mirror came up empty, pulling everything again")
            return LumeCloudPushResult()
        }
        // Taken before diffing: a write landing mid-pass is after the token.
        let history = pushHistory(since: meta.historyToken, in: context)
        var pass = try newPass(scope: history.scope, cursor: meta.nextSeq, in: context)
        do {
            while pass.result.rounds < Self.maxPushRounds {
                let outgoing = try outgoingRecords(pass: &pass, in: context)
                guard !outgoing.isEmpty else { break }
                pass.result.rounds += 1
                let conflicts = try await send(outgoing, pass: &pass, progress: progress, in: context)
                guard !conflicts.isEmpty else { break }
                pass.result.conflicts += conflicts.count
                try mergeConflicts(conflicts, pass: &pass, in: context)
                pass.scope = retryScope(for: conflicts, pass: pass)
            }
            try settle(&pass, historyToken: history.token, meta: meta, in: context)
        } catch {
            if pass.result.mirrorChanged {
                await postMirrorDidChange()
            }
            throw error
        }

        let result = pass.result
        let pushed = result.pushedRecords
        let conflicts = result.conflicts
        let skipped = result.skippedRecords
        Logger.sync.info("Lume Cloud push: \(pushed) records, \(conflicts) conflicts, \(skipped) skipped")
        if result.mirrorChanged {
            await postMirrorDidChange()
        }
        return result
    }

    /// A pass over `scope`, starting from every record for a full diff, else
    /// from the dirty ones.
    private func newPass(scope: LumeCloudPushScope, cursor: Int, in context: ModelContext) throws -> PushPass {
        var pass = PushPass(scope: scope, states: [:], cursor: cursor)
        try loadStates(
            scope.isEverything
                ? FetchDescriptor<LumeCloudRecordState>()
                : FetchDescriptor<LumeCloudRecordState>(predicate: #Predicate { $0.isDirty || $0.isDeletionPending }),
            into: &pass,
            in: context
        )
        return pass
    }

    // MARK: Diffing

    /// Every record to push: an upsert per row whose canonical payload differs
    /// from its last-synced bytes, and a tombstone per recorded deletion. A held
    /// record is never written over or deleted (PROTOCOL.md §2.4).
    private func outgoingRecords(pass: inout PushPass, in context: ModelContext) throws -> [LumeCloudOutgoingRecord] {
        var outgoing: [LumeCloudOutgoingRecord] = []
        let statesByType = Dictionary(grouping: pass.states.values, by: \.type)
        for modelType in LumeCloudPayloadCodec.mappableModels {
            try collectUpserts(of: modelType, statesByType: statesByType, pass: &pass, into: &outgoing, in: context)
        }
        if case .changed = pass.scope {
            // A record held back after a 413 whose row nobody touched since.
            let sending = Set(outgoing.map(\.record.rid))
            for state in pass.states.values where state.isDirty && oversizedRecords[state.rid] != nil
                && !sending.contains(state.rid) && !pass.excluded.contains(state.rid)
            {
                pass.skip(state.rid)
            }
        }
        for state in pass.states.values where state.isDeletionPending && !state.isUndecodable && !pass.excluded.contains(state.rid) {
            guard state.lastSyncedPayload != nil else {
                // Already a tombstone on the server.
                update(state, \.isDeletionPending, to: false)
                update(state, \.isDirty, to: false)
                continue
            }
            outgoing.append(LumeCloudOutgoingRecord(record: .delete(rid: state.rid, baseVersion: state.version), bytes: nil))
        }
        return outgoing
    }

    /// The rows of `Model` this pass diffs, and the bookkeeping this loaded
    /// into the pass for them.
    private func rowsToDiff<Model: LumeCloudPayloadMappable>(
        _: Model.Type,
        pass: inout PushPass,
        in context: ModelContext
    ) throws -> (rows: [Model], loaded: [LumeCloudRecordState]) {
        let candidates: [String: Set<PersistentIdentifier>]
        switch pass.scope {
        case .everything:
            return try (context.fetch(FetchDescriptor<Model>()), [])
        case let .keys(retried):
            guard let retriedKeys = retried[Model.lumeCloudType] else { return ([], []) }
            let rows = try mirrorRows(Model.self, withKeys: retriedKeys, in: context)
            return (rows.filter { retriedKeys.contains($0.lumeCloudKey) }, [])
        case let .changed(changed):
            candidates = changed
        }
        let ids = candidates[Schema.entityName(for: Model.self)] ?? []
        let rows = ids.isEmpty ? [] : try context.fetch(FetchDescriptor<Model>(
            predicate: #Predicate { ids.contains($0.persistentModelID) }
        ))
        let rowKeys = Set(rows.map(\.lumeCloudKey))
        let type = Model.lumeCloudType
        // A dirty record whose row no other writer touched since the token (a
        // send that failed or kept conflicting, or a merge this transport
        // wrote) has a row only a full read of its type finds.
        let stranded = pass.states.values.contains { state in
            state.type == type && state.isDirty && !state.isDeletionPending && !state.isUndecodable
                && oversizedRecords[state.rid] == nil && !rowKeys.contains(state.logicalKey)
        }
        if stranded {
            let loaded = try loadStates(
                FetchDescriptor<LumeCloudRecordState>(predicate: #Predicate { $0.type == type }),
                into: &pass,
                in: context
            )
            return try (context.fetch(FetchDescriptor<Model>()), loaded)
        }
        guard !rows.isEmpty else { return ([], []) }
        let logicalKeys = Array(rowKeys)
        let rids = logicalKeys.map { keys.recordID(for: $0) }
        let loaded = try loadStates(
            FetchDescriptor<LumeCloudRecordState>(
                predicate: #Predicate { rids.contains($0.rid) || logicalKeys.contains($0.logicalKey) }
            ),
            into: &pass,
            in: context
        )
        return (rows, loaded)
    }

    /// The conflicted records a retry round re-diffs, leaving out the ones
    /// this pass gave up on.
    private func retryScope(for conflicts: [RemoteRecord], pass: PushPass) -> LumeCloudPushScope {
        var keys: [String: Set<String>] = [:]
        for conflict in conflicts where !pass.excluded.contains(conflict.rid) {
            guard let state = pass.states[conflict.rid] else { continue }
            keys[state.type, default: []].insert(state.logicalKey)
        }
        return .keys(keys)
    }

    /// Adds the states `descriptor` finds to the pass, returning the ones it
    /// didn't hold yet.
    @discardableResult
    private func loadStates(
        _ descriptor: FetchDescriptor<LumeCloudRecordState>,
        into pass: inout PushPass,
        in context: ModelContext
    ) throws -> [LumeCloudRecordState] {
        var loaded: [LumeCloudRecordState] = []
        for state in try context.fetch(descriptor) where pass.states[state.rid] == nil {
            pass.states[state.rid] = state
            loaded.append(state)
        }
        return loaded
    }

    /// Collapses rows sharing a logical key to the newest, then seals each row
    /// that changed since it last synced.
    private func collectUpserts<Model: LumeCloudPayloadMappable>(
        of _: Model.Type,
        statesByType: [String: [LumeCloudRecordState]],
        pass: inout PushPass,
        into outgoing: inout [LumeCloudOutgoingRecord],
        in context: ModelContext
    ) throws {
        let type = Model.lumeCloudType
        let diffed = try rowsToDiff(Model.self, pass: &pass, in: context)
        let groups = try duplicateGroups(of: diffed.rows, scope: pass.scope, in: context)
        let typeStates = (statesByType[type] ?? []) + diffed.loaded.filter { $0.type == type }
        let statesByKey = Dictionary(
            typeStates.map { ($0.logicalKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (key, rows) in groups {
            guard let row = newest(of: rows, in: context, pass: &pass) else { continue }
            let state = statesByKey[key]
            if let state {
                // The row exists again, so it is no longer deleted.
                update(state, \.isDeletionPending, to: false)
            }
            upsertEncodeCount += 1
            let bytes = try LumeCloudPayloadCodec.encoded(row, previous: state?.lastSyncedPayload)
            guard bytes != state?.lastSyncedPayload else {
                if let state {
                    update(state, \.isDirty, to: false)
                }
                continue
            }
            let rid = state?.rid ?? keys.recordID(for: key)
            guard !pass.excluded.contains(rid) else { continue }
            // Looked up by `rid`: a record held unread has no logical key yet.
            guard pass.states[rid]?.isUndecodable != true else {
                pass.skip(rid)
                continue
            }
            guard oversizedRecords[rid] != bytes else {
                pass.skip(rid)
                continue
            }
            guard bytes.count + Self.envelopeOverhead <= LumeCloudAPI.maxRecordBytes else {
                pass.skip(rid)
                Logger.sync.error("Lume Cloud push skipped a \(type) record over the size limit")
                continue
            }
            let outgoingState = state ?? recordState(rid: rid, key: key, type: type, states: &pass.states, in: context)
            update(outgoingState, \.isDirty, to: true)
            try outgoing.append(LumeCloudOutgoingRecord(
                record: .upsert(rid: rid, baseVersion: outgoingState.version, ciphertext: keys.seal(bytes, rid: rid)),
                bytes: bytes
            ))
        }
    }

    /// `rows` grouped by logical key. A partial pass sees only the rows that
    /// changed, so untouched duplicates of their keys join the group: a
    /// different winner than a full diff would pick could flip the pushed value.
    private func duplicateGroups<Model: LumeCloudPayloadMappable>(
        of rows: [Model],
        scope: LumeCloudPushScope,
        in context: ModelContext
    ) throws -> [String: [Model]] {
        let groups = Dictionary(grouping: rows, by: \.lumeCloudKey)
        if case .everything = scope { return groups }
        guard !groups.isEmpty else { return groups }
        let keys = Set(groups.keys)
        let all = try mirrorRows(Model.self, withKeys: keys, in: context).filter { keys.contains($0.lumeCloudKey) }
        return Dictionary(grouping: all, by: \.lumeCloudKey)
    }

    /// The `MirrorDuplicates` survivor of rows sharing a logical key; the
    /// others are deleted from the mirror.
    private func newest<Model: LumeCloudPayloadMappable>(
        of rows: [Model],
        in context: ModelContext,
        pass: inout PushPass
    ) -> Model? {
        guard rows.count > 1 else { return rows.first }
        let newest = MirrorDuplicates.survivor(of: rows, updatedAt: \.updatedAt)
        for row in rows where row !== newest {
            context.delete(row)
        }
        pass.result.mirrorChanged = true
        return newest
    }

    // MARK: Sending

    /// Sends `outgoing` in batches and stores each success as the record's new
    /// version and merge base. Returns the server's current record for every
    /// conflict.
    private func send(
        _ outgoing: [LumeCloudOutgoingRecord],
        pass: inout PushPass,
        progress: (@Sendable (LumeCloudUploadProgress) -> Void)?,
        in context: ModelContext
    ) async throws -> [RemoteRecord] {
        let batches = Self.batches(outgoing)
        let reportsProgress = batches.count > 1
        var completed = 0
        if reportsProgress {
            progress?(LumeCloudUploadProgress(completed: 0, total: outgoing.count))
        }
        var conflicts: [RemoteRecord] = []
        var queue = batches
        var unsavedRequests = 0
        do {
            while !queue.isEmpty {
                let batch = queue.removeFirst()
                switch try await pushOrSplit(batch, queue: &queue, pass: &pass) {
                case let .sent(response):
                    apply(response, sent: batch, pass: &pass, conflicts: &conflicts)
                    unsavedRequests += 1
                    if unsavedRequests >= Self.requestsPerSave {
                        try context.save()
                        unsavedRequests = 0
                    }
                case .split:
                    continue
                case .skipped:
                    break
                }
                completed += batch.count
                if reportsProgress {
                    progress?(LumeCloudUploadProgress(completed: completed, total: outgoing.count))
                }
            }
        } catch {
            // A later failure keeps what earlier requests applied.
            if context.hasChanges {
                try? context.save()
            }
            throw error
        }
        if context.hasChanges {
            try context.save()
        }
        return conflicts
    }

    private nonisolated enum BatchOutcome {
        case sent(PushResponse)
        /// Rejected as too large and halved back onto the queue.
        case split
        /// A lone record rejected as too large, left out of this pass.
        case skipped
    }

    /// Sends one request. The server rejects a whole request for one record
    /// that is too large, so a rejected batch is halved until that record is found.
    private func pushOrSplit(
        _ batch: [LumeCloudOutgoingRecord],
        queue: inout [[LumeCloudOutgoingRecord]],
        pass: inout PushPass
    ) async throws -> BatchOutcome {
        do {
            return try await .sent(request { try await client.push(batch.map(\.record)) })
        } catch LumeCloudError.recordTooLarge {
            guard batch.count > 1 else {
                skipOversized(batch, pass: &pass)
                return .skipped
            }
            let middle = batch.count / 2
            queue.insert(contentsOf: [Array(batch[..<middle]), Array(batch[middle...])], at: 0)
            return .split
        } catch LumeCloudError.quotaExceeded {
            noteQuotaExceeded()
            Logger.sync.error("Lume Cloud push stopped: the account is over its quota")
            throw LumeCloudError.quotaExceeded
        }
    }

    /// Stores each success as the record's new version and merge base, and
    /// collects the server's current record for each conflict. A record the
    /// response doesn't answer stays dirty for the next pass.
    private func apply(
        _ response: PushResponse,
        sent batch: [LumeCloudOutgoingRecord],
        pass: inout PushPass,
        conflicts: inout [RemoteRecord]
    ) {
        noteServerSeqs(of: response, pass: &pass)
        let sent = Dictionary(batch.map { ($0.record.rid, $0) }, uniquingKeysWith: { first, _ in first })
        for result in response.results {
            switch result {
            case let .ok(rid, version, _):
                guard let record = sent[rid], let state = pass.states[rid] else { continue }
                update(state, \.version, to: version)
                update(state, \.lastSyncedPayload, to: record.bytes)
                update(state, \.isDirty, to: false)
                update(state, \.isDeletionPending, to: false)
                pass.result.pushedRecords += 1
            case let .conflict(rid, current):
                guard sent[rid] != nil else { continue }
                conflicts.append(current)
            }
        }
    }

    /// Ends a pass that sent everything it could: saves the bookkeeping and
    /// stores `historyToken`. When the pass found the server's feed behind the
    /// stored cursor, the stored seqs and versions are another feed's: start
    /// over from 0. The mirror stays, so the snapshot pull merges into it and
    /// only records this feed lacks are pushed again.
    private func settle(
        _ pass: inout PushPass,
        historyToken: Data?,
        meta: LumeCloudSyncMeta,
        in context: ModelContext
    ) throws {
        if context.hasChanges {
            try context.save()
        }
        try storeHistoryToken(historyToken, meta: meta, in: context)
        guard pass.cursorAheadOfFeed else { return }
        Logger.sync.notice("Lume Cloud cursor is ahead of the server's feed: pulling everything again")
        try resetBookkeeping(meta, keepingHeldRecords: true, in: context)
        try context.save()
        pass.result.feedRewound = true
    }

    /// Checks the stored cursor against the seqs the server just reported.
    /// Every seq of a feed this device pulled from is below its next seq to
    /// assign, and below each seq it assigns to this push's writes. A cursor
    /// at or past one of them came from another feed: the account moved
    /// between servers, or the server was restored from a backup. Such a
    /// cursor skips every record up to it, so pulls from it miss the other
    /// devices' writes (PROTOCOL.md: clients that see older `seq`s resync).
    private func noteServerSeqs(of response: PushResponse, pass: inout PushPass) {
        guard pass.cursor > 0 else { return }
        let assigned = response.results.compactMap { result -> Int? in
            if case let .ok(_, _, seq) = result { seq } else { nil }
        }
        let lowest = assigned.min() ?? response.nextSeq
        if lowest <= pass.cursor {
            pass.cursorAheadOfFeed = true
        }
    }

    /// A lone record the server answered with 413. It stays dirty but isn't sent
    /// again until its payload changes. The log names its type only.
    private func skipOversized(_ batch: [LumeCloudOutgoingRecord], pass: inout PushPass) {
        for record in batch {
            let rid = record.record.rid
            pass.skip(rid)
            if let bytes = record.bytes {
                oversizedRecords[rid] = bytes
            }
            let type = pass.states[rid]?.type ?? "unknown"
            Logger.sync.error("Lume Cloud push skipped a \(type) record the server rejected as too large")
        }
    }

    /// `records` split into requests within the server's record-count and
    /// body-size caps (PROTOCOL.md §4.4).
    nonisolated static func batches(_ records: [LumeCloudOutgoingRecord]) -> [[LumeCloudOutgoingRecord]] {
        var batches: [[LumeCloudOutgoingRecord]] = []
        var current: [LumeCloudOutgoingRecord] = []
        var bodyBytes = pushBodyOverhead
        for record in records {
            let size = (record.record.ciphertext?.utf8.count ?? 0) + pushRecordOverhead
            if !current.isEmpty, current.count == LumeCloudAPI.maxPushRecords || bodyBytes + size > maxPushBodyBytes {
                batches.append(current)
                current = []
                bodyBytes = pushBodyOverhead
            }
            current.append(record)
            bodyBytes += size
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    // MARK: Conflicts

    /// Merges each conflict's server record into the mirror exactly as a pull
    /// would, which also moves the record's base version to the server's.
    private func mergeConflicts(_ conflicts: [RemoteRecord], pass: inout PushPass, in context: ModelContext) throws {
        let interval = Perf.begin(.lumeCloudMerge)
        defer { Perf.end(interval) }
        let outcome = try mergeRemote(conflicts, states: &pass.states, in: context)
        pass.result.mirrorChanged = pass.result.mirrorChanged || outcome.changed
        // A server version this build couldn't read or decode left the base
        // version as it was, so a retry would only conflict again.
        for current in conflicts where pass.states[current.rid]?.version != current.version {
            pass.skip(current.rid)
        }
        if context.hasChanges {
            try context.save()
        }
    }
}
