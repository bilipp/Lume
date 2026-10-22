import Foundation
import LumeCloudKit

nonisolated extension LumeCloudSyncState {
    /// The state a failed request leaves Lume Cloud in. `nil` for errors that
    /// don't change the connection state; those surface as `lastError` only.
    init?(error: LumeCloudError) {
        switch error {
        case .deviceRevoked: self = .revoked
        case .accountDeleted: self = .accountDeleted
        case .rateLimited: self = .rateLimited
        case .quotaExceeded: self = .quotaExceeded
        case .transport: self = .offline
        case .badRequest, .badAuth, .signupClosed, .notFound, .accountExists, .pairingAlreadySealed, .resyncRequired,
             .recordTooLarge, .server, .decoding, .missingCredentials:
            return nil
        }
    }
}
