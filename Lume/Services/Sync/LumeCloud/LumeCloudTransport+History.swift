import Foundation
import OSLog
import SwiftData

/// Which mirror rows a push diffs.
nonisolated enum LumeCloudPushScope {
    /// Every row of every mirror model.
    case everything
    /// The rows another writer inserted or updated since the stored history
    /// token, by entity name. A deleted row has nothing to send: tombstones come
    /// only from `recordDeletion`, which marks its record dirty.
    case changed([String: Set<PersistentIdentifier>])
    /// The rows under these logical keys, by record type: a conflict retry
    /// re-diffs only the records that conflicted.
    case keys([String: Set<String>])

    var isEverything: Bool {
        if case .everything = self { true } else { false }
    }
}

/// What a push read from persistent history before diffing.
nonisolated struct LumeCloudPushHistory {
    var scope: LumeCloudPushScope
    /// The encoded token of the newest transaction this push covers, stored
    /// once it succeeds. Nil leaves the next push diffing every row.
    var token: Data?
}

/// History-based change detection for pushes. Every transport context writes
/// as `contextAuthor`, so any other author's transaction on a mirror model is
/// a local change the server hasn't seen.
///
/// Persistent history of the Lume Cloud store is the transport's alone: the
/// store is local-only (no CloudKit export reads it), lives outside the app
/// group, and nothing else fetches its history; `CloudSyncEngine` and the
/// services that write the mirror never do. So once a token is stored, every
/// transaction before it, whoever wrote it, has been diffed and is deleted.
/// `ContentSyncManager.purgeCatalogHistory` still never touches this store.
extension LumeCloudTransport {
    /// More changed rows than this and a full diff costs no more than the
    /// lookups, whose `IN` lists would also near SQLite's variable limit.
    nonisolated static let maxHistoryCandidates = 2000
    nonisolated static let historyStartToken = Data()

    private nonisolated static var mirrorEntityNames: Set<String> {
        func entityName<Model: PersistentModel>(_: Model.Type) -> String {
            Schema.entityName(for: Model.self)
        }
        return Set(LumeCloudPayloadCodec.mappableModels.map { modelType in entityName(modelType) })
    }

    private nonisolated static var syncMetaEntityName: String {
        Schema.entityName(for: LumeCloudSyncMeta.self)
    }

    /// The rows to diff since `storedToken`, and the token to store after.
    func pushHistory(since storedToken: Data?, in context: ModelContext) -> LumeCloudPushHistory {
        guard let storedToken else { return fullDiffHistory(in: context) }
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try history(after: storedToken, in: context)
        } catch {
            if let error = error as? SwiftDataError, error == .historyTokenExpired {
                Logger.sync.notice("Lume Cloud push history token expired: diffing every row")
            } else {
                Logger.sync.error("Lume Cloud push history unreadable: diffing every row")
            }
            return fullDiffHistory(in: context)
        }

        let relevant = transactions.filter { !isOwnSyncMetaWrite($0) }
        let newest = relevant.map(\.token).max()
        let token = try? newest.map(Self.encode) ?? storedToken
        let candidates = Self.changedMirrorRows(in: relevant.filter { $0.author != Self.contextAuthor })
        guard candidates.values.reduce(0, { $0 + $1.count }) <= Self.maxHistoryCandidates else {
            return LumeCloudPushHistory(scope: .everything, token: token)
        }
        return LumeCloudPushHistory(scope: .changed(candidates), token: token)
    }

    /// The mirror rows `transactions` inserted or updated, by entity name.
    private nonisolated static func changedMirrorRows(
        in transactions: [DefaultHistoryTransaction]
    ) -> [String: Set<PersistentIdentifier>] {
        let mirrorEntities = mirrorEntityNames
        var rows: [String: Set<PersistentIdentifier>] = [:]
        for change in transactions.flatMap(\.changes) {
            if case .delete = change { continue }
            let id = change.changedPersistentIdentifier
            guard mirrorEntities.contains(id.entityName) else { continue }
            rows[id.entityName, default: []].insert(id)
        }
        return rows
    }

    /// A full diff covers every transaction so far, so their history goes
    /// first: reading it back would cost more than the diff it replaces.
    private func fullDiffHistory(in context: ModelContext) -> LumeCloudPushHistory {
        do {
            try context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            let newest = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).map(\.token).max()
            let token = try newest.map(Self.encode) ?? Self.historyStartToken
            return LumeCloudPushHistory(scope: .everything, token: token)
        } catch {
            Logger.sync.error("Lume Cloud push history unreadable: the next push diffs every row again")
            return LumeCloudPushHistory(scope: .everything, token: nil)
        }
    }

    /// Stores `token` after a successful push, moved past the push's own
    /// writes unless another writer's transaction came between, then deletes
    /// the history before it. Nil clears the stored token.
    func storeHistoryToken(_ token: Data?, meta: LumeCloudSyncMeta, in context: ModelContext) throws {
        var stored = token
        if let token, let caughtUp = try? ownTransactionsEnd(after: token, in: context) {
            stored = caughtUp
        }
        update(meta, \.historyToken, to: stored)
        if context.hasChanges {
            try context.save()
        }
        guard let stored, stored != Self.historyStartToken,
              let decoded = try? Self.decode(stored)
        else { return }
        do {
            try context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate { $0.token < decoded }
            ))
        } catch {
            Logger.sync.error("Lume Cloud push history purge failed")
        }
    }

    /// The token of the last transport write after `token` that no other
    /// writer's transaction precedes; nil when there is none.
    private func ownTransactionsEnd(after token: Data, in context: ModelContext) throws -> Data? {
        var end: DefaultHistoryToken?
        for transaction in try history(after: token, in: context).sorted(by: { $0.token < $1.token }) {
            guard transaction.author == Self.contextAuthor else { break }
            if !isOwnSyncMetaWrite(transaction) {
                end = transaction.token
            }
        }
        return try end.map(Self.encode)
    }

    private func history(after token: Data, in context: ModelContext) throws -> [DefaultHistoryTransaction] {
        guard token != Self.historyStartToken else {
            return try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        }
        let decoded = try Self.decode(token)
        return try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.token > decoded }
        ))
    }

    private nonisolated static func encode(_ token: DefaultHistoryToken) throws -> Data {
        try JSONEncoder().encode(token)
    }

    private nonisolated static func decode(_ data: Data) throws -> DefaultHistoryToken {
        try JSONDecoder().decode(DefaultHistoryToken.self, from: data)
    }

    /// A transport write to `LumeCloudSyncMeta` alone, such as storing the
    /// token itself. Moving the token past one would need another such write,
    /// so the token never does: re-reading them costs next to nothing.
    private func isOwnSyncMetaWrite(_ transaction: DefaultHistoryTransaction) -> Bool {
        let metaEntity = Self.syncMetaEntityName
        return transaction.author == Self.contextAuthor
            && transaction.changes.allSatisfy { $0.changedPersistentIdentifier.entityName == metaEntity }
    }
}
