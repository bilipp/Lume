//
//  StubLumeCloudClient.swift
//  LumeTests
//
//  An in-memory Lume Cloud change feed behind `LumeCloudSyncing`, so the
//  transport is tested without the network. It follows PROTOCOL.md §4.3/§4.4:
//  every write gets a fresh `seq` and bumps the record's version, a record
//  appears once at its latest `seq`, `since == 0` lists live records only, and a
//  push applies a record only when its `baseVersion` matches.
//

import Foundation
@testable import Lume
import LumeCloudKit
import Synchronization

final nonisolated class StubLumeCloudClient: LumeCloudSyncing {
    struct State {
        var records: [String: RemoteRecord] = [:]
        var lastSeq = 0
        /// Every `since` the transport asked for, in order.
        var requestedSince: [Int] = []
        /// `since` values in `1 ..< compactedSeq` throw `.resyncRequired`.
        var compactedSeq = 0
        var pushes: [[PushRecord]] = []
        /// Every push request, failed ones included.
        var pushAttempts = 0
        /// Every `GET /v1/accounts/me`.
        var accountRequests = 0
    }

    let state = Mutex(State())
    let keys: LumeCloudKeys
    /// Runs before each push is applied, e.g. to simulate another device writing.
    let beforePush = Mutex<(@Sendable (StubLumeCloudClient) throws -> Void)?>(nil)
    /// The error a `/changes` request with this `since` fails with, if any.
    let changesError = Mutex<(@Sendable (Int) -> LumeCloudError?)?>(nil)
    /// The error a push request fails with as a whole, if any; nothing applies.
    let pushError = Mutex<(@Sendable ([PushRecord]) -> LumeCloudError?)?>(nil)
    /// Every socket opened by `events()`, in order; the last one is current.
    let sockets = Mutex<[AsyncThrowingStream<Int, Error>.Continuation]>([])
    /// The error the socket with this index (0-based) fails with on opening, if any.
    let socketError = Mutex<(@Sendable (Int) -> LumeCloudError?)?>(nil)

    init(keys: LumeCloudKeys) {
        self.keys = keys
    }

    var requestedSince: [Int] {
        state.withLock(\.requestedSince)
    }

    /// Every push request, in order.
    var pushes: [[PushRecord]] {
        state.withLock(\.pushes)
    }

    var pushAttempts: Int {
        state.withLock(\.pushAttempts)
    }

    var accountRequests: Int {
        state.withLock(\.accountRequests)
    }

    /// `nextSeq` is the next seq this feed assigns.
    func account() async throws -> AccountInfo {
        state.withLock { state in
            state.accountRequests += 1
            return AccountInfo(
                accountId: "acct-stub", createdAt: 1_760_000_000_000, usedBytes: 0,
                recordCount: state.records.count, nextSeq: state.lastSeq + 1
            )
        }
    }

    func record(forKey logicalKey: String) -> RemoteRecord? {
        let rid = keys.recordID(for: logicalKey)
        return state.withLock { $0.records[rid] }
    }

    /// The decrypted payload stored under `logicalKey`; nil for a tombstone.
    func payload(forKey logicalKey: String) throws -> LumeCloudPayload? {
        guard let record = record(forKey: logicalKey), let ciphertext = record.ciphertext else { return nil }
        return try keys.openPayload(ciphertext, rid: record.rid)
    }

    /// Seals `payload` and stores it as the record's next version.
    @discardableResult
    func upsert(_ payload: LumeCloudPayload) throws -> RemoteRecord {
        let (rid, ciphertext) = try keys.seal(payload)
        return store(rid: rid, ciphertext: ciphertext)
    }

    /// Stores raw ciphertext, e.g. an envelope this build can't read.
    @discardableResult
    func store(rid: String, ciphertext: String?) -> RemoteRecord {
        state.withLock { state in
            state.lastSeq += 1
            let record = RemoteRecord(
                rid: rid,
                version: (state.records[rid]?.version ?? 0) + 1,
                seq: state.lastSeq,
                deleted: ciphertext == nil,
                ciphertext: ciphertext,
                updatedAt: 1_760_000_000_000 + state.lastSeq
            )
            state.records[rid] = record
            return record
        }
    }

    /// Replaces the record under `logicalKey` with a tombstone.
    func delete(logicalKey: String) {
        store(rid: keys.recordID(for: logicalKey), ciphertext: nil)
    }

    /// Drops every record from the feed, as tombstone purging does, and makes
    /// older cursors stale.
    func compact() {
        state.withLock { state in
            state.records = state.records.filter { !$0.value.deleted }
            state.compactedSeq = state.lastSeq
        }
    }

    func allChanges(since: Int, limit _: Int?) async throws -> ChangesPage {
        let error = changesError.withLock { $0 }?(since)
        return try state.withLock { state in
            state.requestedSince.append(since)
            if let error {
                throw error
            }
            if since > 0, since < state.compactedSeq {
                throw LumeCloudError.resyncRequired
            }
            let records = state.records.values
                .filter { $0.seq > since && (since > 0 || !$0.deleted) }
                .sorted { $0.seq < $1.seq }
            return ChangesPage(records: records, nextSeq: records.last?.seq ?? since, hasMore: false)
        }
    }

    func changes(since: Int, limit: Int?) async throws -> ChangesPage {
        var page = try await allChanges(since: since, limit: limit)
        if let limit, page.records.count > limit {
            page = ChangesPage(records: Array(page.records.prefix(limit)), nextSeq: page.records[limit - 1].seq, hasMore: true)
        }
        return page
    }

    func events() -> AsyncThrowingStream<Int, Error> {
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let index = sockets.withLock { sockets in
            sockets.append(continuation)
            return sockets.count - 1
        }
        if let error = socketError.withLock({ $0 })?(index) {
            continuation.finish(throwing: error)
        }
        return stream
    }

    var socketCount: Int {
        sockets.withLock(\.count)
    }

    /// Sends a poke on the current socket: the feed's highest assigned seq.
    func poke() {
        let seq = state.withLock(\.lastSeq)
        _ = sockets.withLock { $0.last }?.yield(seq)
    }

    /// Ends the current socket, normally or with `error`.
    func dropSocket(throwing error: LumeCloudError? = nil) {
        let socket = sockets.withLock { $0.last }
        if let error {
            socket?.finish(throwing: error)
        } else {
            socket?.finish()
        }
    }

    func push(_ records: [PushRecord]) async throws -> PushResponse {
        state.withLock { $0.pushAttempts += 1 }
        if let error = pushError.withLock({ $0 })?(records) {
            throw error
        }
        try beforePush.withLock { $0 }?(self)
        return state.withLock { state in
            state.pushes.append(records)
            let results = records.map { record -> PushResult in
                let stored = state.records[record.rid]
                let version = stored?.version ?? 0
                guard record.baseVersion == version else {
                    let current = stored ?? RemoteRecord(
                        rid: record.rid, version: 0, seq: 0, deleted: true, ciphertext: nil, updatedAt: 0
                    )
                    return .conflict(rid: record.rid, current: current)
                }
                state.lastSeq += 1
                state.records[record.rid] = RemoteRecord(
                    rid: record.rid,
                    version: version + 1,
                    seq: state.lastSeq,
                    deleted: record.deleted,
                    ciphertext: record.deleted ? nil : record.ciphertext,
                    updatedAt: 1_760_000_000_000 + state.lastSeq
                )
                return .ok(rid: record.rid, version: version + 1, seq: state.lastSeq)
            }
            return PushResponse(results: results, nextSeq: state.lastSeq + 1)
        }
    }
}
