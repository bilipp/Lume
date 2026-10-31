import Foundation
import SwiftData

/// The Lume Cloud transport's per-account sync state. Local-only, in
/// `LumeCloudUserData.store`; a singleton (`id` is always `Self.singletonID`).
@Model
final class LumeCloudSyncMeta {
    static let singletonID = "sync-meta"

    @Attribute(.unique) var id: String = LumeCloudSyncMeta.singletonID
    /// The pull cursor: the `nextSeq` of the last `/changes` response. Never
    /// advanced from a push response, whose `nextSeq` is the server's next seq to
    /// assign rather than a cursor. 0 pulls everything.
    var nextSeq: Int = 0
    /// The account this bookkeeping belongs to. A mismatch with the active account
    /// means the bookkeeping is stale and must be reset.
    var accountId: String = ""
    /// The server whose feed `nextSeq` and every record's `version` come from,
    /// as `LumeCloudConfig.comparable`. The account id is derived from the root
    /// key, so it stays the same when an account moves between servers (staging
    /// to production, a self-hosted server); `seq`s and versions don't. A
    /// different server resets the bookkeeping. Empty for bookkeeping written
    /// before this was recorded: adopted as the current server.
    var serverURL: String = ""
    /// The JSON-encoded `DefaultHistoryToken` a push last diffed through: the
    /// next push diffs only rows other writers changed after it. Nil makes the
    /// next push diff every row. Empty means history held no transaction yet,
    /// so every transaction is newer.
    var historyToken: Data?

    init(nextSeq: Int = 0, accountId: String = "") {
        self.nextSeq = nextSeq
        self.accountId = accountId
    }
}
