import Foundation
import LumeCloudKit

/// The realtime socket (PROTOCOL.md §4.6) over the transport's client.
extension LumeCloudTransport {
    /// The account's feed `seq` each time it advances. Never reconnects.
    nonisolated func events() -> AsyncThrowingStream<Int, Error> {
        client.events()
    }

    /// A failed socket upgrade can't say why: a one-record `/changes` request
    /// from the stored cursor throws the precise error (`device_revoked`,
    /// `account_deleted`, …). Nothing it returns is applied.
    func probeAccess() async throws {
        let since = try storedCursor()
        _ = try await request { try await client.changes(since: since, limit: 1) }
    }
}
