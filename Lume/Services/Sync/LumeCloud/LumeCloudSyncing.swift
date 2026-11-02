import Foundation
import LumeCloudKit

/// The authenticated sync calls `LumeCloudTransport` makes. A seam over
/// `LumeCloudClient` so tests drive the transport offline.
///
/// Like the client, an implementation never retries: backoff, conflict rounds
/// and resyncs are the transport's job.
nonisolated protocol LumeCloudSyncing: Sendable {
    /// `GET /v1/changes` from `since` until `hasMore` is false.
    func allChanges(since: Int, limit: Int?) async throws -> ChangesPage
    /// `POST /v1/push` — at most `LumeCloudAPI.maxPushRecords` records.
    func push(_ records: [PushRecord]) async throws -> PushResponse
    /// One `GET /v1/changes` page.
    func changes(since: Int, limit: Int?) async throws -> ChangesPage
    /// `GET /v1/socket`: the feed's `seq` each time it advances. Never reconnects.
    func events() -> AsyncThrowingStream<Int, Error>
    /// `GET /v1/accounts/me`. Its `nextSeq` is the next seq the server will
    /// assign: never a cursor, but every cursor of this feed is below it.
    func account() async throws -> AccountInfo
}

/// `LumeCloudSyncing` over the real server.
nonisolated struct LiveLumeCloudSyncing: LumeCloudSyncing {
    private let client: LumeCloudClient
    private let socketClient: LumeCloudClient

    init(baseURL: URL, credentials: LumeCloudClient.Credentials) {
        client = LumeCloudClient(baseURL: baseURL, session: Self.session, credentials: credentials)
        socketClient = LumeCloudClient(baseURL: baseURL, session: Self.socketSession, credentials: credentials)
    }

    /// Ephemeral: no cookies, no cache, nothing of the account written to disk.
    /// Fails fast when offline instead of waiting, since every pass is retried by
    /// the next trigger anyway.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// The socket's own session: the sync session's resource timeout would cut
    /// a long-lived socket after two minutes. The client pings every 30 s, so a
    /// socket idle for longer than the request timeout is dead.
    static let socketSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func allChanges(since: Int, limit: Int?) async throws -> ChangesPage {
        try await client.allChanges(since: since, limit: limit)
    }

    func push(_ records: [PushRecord]) async throws -> PushResponse {
        try await client.push(records)
    }

    func changes(since: Int, limit: Int?) async throws -> ChangesPage {
        try await client.changes(since: since, limit: limit)
    }

    func events() -> AsyncThrowingStream<Int, Error> {
        socketClient.events()
    }

    func account() async throws -> AccountInfo {
        try await client.account()
    }
}
