//
//  PerfLumeCloudFeed.swift
//  LumePerformanceTests
//
//  The smallest `LumeCloudSyncing` that lets `LumeCloudTransport` push and pull
//  without a network: every push is accepted at the next version, and
//  `/changes` lists what was stored after the cursor.
//

import Foundation
@testable import Lume
import LumeCloudKit
import Synchronization

final nonisolated class PerfLumeCloudFeed: LumeCloudSyncing {
    private struct State {
        var records: [String: RemoteRecord] = [:]
        var lastSeq = 0
        var pushRequests = 0
    }

    private let state = Mutex(State())

    /// Push requests received so far: one per batch the transport sent.
    var pushRequestCount: Int {
        state.withLock { $0.pushRequests }
    }

    func allChanges(since: Int, limit _: Int?) async throws -> ChangesPage {
        state.withLock { state in
            let records = state.records.values
                .filter { $0.seq > since && (since > 0 || !$0.deleted) }
                .sorted { $0.seq < $1.seq }
            return ChangesPage(records: records, nextSeq: records.last?.seq ?? since, hasMore: false)
        }
    }

    func changes(since: Int, limit: Int?) async throws -> ChangesPage {
        try await allChanges(since: since, limit: limit)
    }

    func events() -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func push(_ records: [PushRecord]) async throws -> PushResponse {
        state.withLock { state in
            state.pushRequests += 1
            let results = records.map { record -> PushResult in
                let version = (state.records[record.rid]?.version ?? 0) + 1
                state.lastSeq += 1
                state.records[record.rid] = RemoteRecord(
                    rid: record.rid,
                    version: version,
                    seq: state.lastSeq,
                    deleted: record.deleted,
                    ciphertext: record.deleted ? nil : record.ciphertext,
                    updatedAt: 1_800_000_000_000 + state.lastSeq
                )
                return .ok(rid: record.rid, version: version, seq: state.lastSeq)
            }
            return PushResponse(results: results, nextSeq: state.lastSeq + 1)
        }
    }
}
