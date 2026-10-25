//
//  DispatcharrChannelDirectory.swift
//  Lume
//
//  In-memory copy of the channels a Dispatcharr account can see, keyed by
//  server and account: the names and logos of its recordings, and the
//  stream-uuid → channel-id map of an M3U playlist served by the server. One
//  unpaginated GET fills it; concurrent callers share that GET, and a failed
//  one is remembered briefly instead of being repeated by every poll.
//

import Foundation

actor DispatcharrChannelDirectory {
    static let shared = DispatcharrChannelDirectory()

    nonisolated static let maxAge: TimeInterval = 10 * 60
    nonisolated static let failureBackoff: TimeInterval = 60

    nonisolated struct Key: Hashable {
        let baseURL: URL
        /// `DispatcharrCredential.identityUser`: channel visibility is per account.
        let user: String
    }

    nonisolated struct Snapshot: Hashable {
        static let empty = Snapshot(channels: [])

        let byID: [Int: DispatcharrChannel]
        let idsByUUID: [UUID: Int]

        init(channels: [DispatcharrChannel]) {
            byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            idsByUUID = Dictionary(
                channels.compactMap { channel in channel.uuid.map { ($0, channel.id) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    typealias Fetch = @Sendable () async throws(RecordingServerError) -> [DispatcharrChannel]

    private nonisolated struct Entry {
        let snapshot: Snapshot
        let expiresAt: Date
    }

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<Snapshot, any Error>] = [:]

    /// The cached channels for `key`, fetched through `fetch` when there are
    /// none or they are older than `maxAge`. A failed fetch yields `.empty`.
    func snapshot(for key: Key, now: Date, fetch: @escaping Fetch) async -> Snapshot {
        if let entry = entries[key], entry.expiresAt > now {
            return entry.snapshot
        }
        if let task = inFlight[key] {
            return await (try? task.value) ?? .empty
        }
        let task = Task<Snapshot, any Error> { try await Snapshot(channels: fetch()) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let snapshot = try await task.value
            entries[key] = Entry(snapshot: snapshot, expiresAt: now.addingTimeInterval(Self.maxAge))
            return snapshot
        } catch {
            entries[key] = Entry(snapshot: .empty, expiresAt: now.addingTimeInterval(Self.failureBackoff))
            return .empty
        }
    }
}
