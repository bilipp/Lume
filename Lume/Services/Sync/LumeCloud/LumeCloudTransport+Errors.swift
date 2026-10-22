import Foundation
import LumeCloudKit

/// How the transport answers the server's back-pressure (PROTOCOL.md §1): 429
/// holds every request until `Retry-After` has passed, 507 holds pushes while
/// pulls go on. Both are thrown again locally, without a request, so the
/// coordinator keeps showing the state while it lasts.
extension LumeCloudTransport {
    /// The wait after consecutive 429s without `Retry-After`.
    nonisolated static let rateLimitBackoff = LumeCloudEventListener.Backoff(initial: .seconds(30), maximum: .seconds(15 * 60))
    /// The longest `Retry-After` honoured, so a bogus header can't stall sync for days.
    nonisolated static let maxRetryAfter: TimeInterval = 60 * 60
    /// How long pushes wait after a 507 unless a deletion frees space first.
    nonisolated static let quotaRetryInterval: TimeInterval = 60 * 60

    /// Whether pushes are held after a 507.
    var isQuotaExceeded: Bool {
        guard let quotaExceededAt else { return false }
        return now().timeIntervalSince(quotaExceededAt) < Self.quotaRetryInterval
    }

    /// Sends one request unless a 429 still holds, and records a new 429.
    func request<Response: Sendable>(_ send: () async throws -> Response) async throws -> Response {
        try throwIfRateLimited()
        do {
            let response = try await send()
            consecutiveRateLimits = 0
            return response
        } catch let LumeCloudError.rateLimited(retryAfter) {
            noteRateLimit(retryAfter: retryAfter)
            throw LumeCloudError.rateLimited(retryAfter: retryAfter)
        }
    }

    func throwIfRateLimited() throws {
        guard let rateLimitedUntil else { return }
        let remaining = rateLimitedUntil.timeIntervalSince(now())
        guard remaining > 0 else {
            self.rateLimitedUntil = nil
            return
        }
        throw LumeCloudError.rateLimited(retryAfter: remaining)
    }

    private func noteRateLimit(retryAfter: TimeInterval?) {
        consecutiveRateLimits += 1
        let delay = if let retryAfter {
            min(max(retryAfter, 0), Self.maxRetryAfter)
        } else {
            Self.rateLimitBackoff.delay(afterFailures: consecutiveRateLimits) / .seconds(1)
        }
        rateLimitedUntil = now().addingTimeInterval(delay)
    }

    func throwIfQuotaExceeded() throws {
        guard quotaExceededAt != nil else { return }
        guard isQuotaExceeded else {
            quotaExceededAt = nil
            return
        }
        throw LumeCloudError.quotaExceeded
    }

    func noteQuotaExceeded() {
        quotaExceededAt = now()
    }

    /// A deletion may have freed enough space, so the next push tries again.
    func liftQuotaHold() {
        quotaExceededAt = nil
    }
}
