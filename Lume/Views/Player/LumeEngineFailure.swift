import LumeEngine

/// Why a LumeEngine stream stopped, read from the engine's typed error.
///
/// The engine only classifies (bilipp/LumeEngine#45); what each cause gets —
/// a fresh stream URL, a slower reconnect, no reconnect at all — is Lume's
/// call, made by the player views.
nonisolated enum LumeEngineFailure: String, EngineFailurePolicy {
    /// No cause worth acting on: the stall watchdog, a dropped connection, a
    /// decoder fault, a 400 or another 4xx. Reconnects on the normal schedule.
    case interrupted
    /// A live source reached a clean end, typically an HLS playlist that gained
    /// `#EXT-X-ENDLIST` mid-broadcast. A lost source, not a fault.
    case sourceEnded
    /// HTTP 401 / 403: an expired token, or a connection slot still held by a
    /// previous session.
    case unauthorized
    /// HTTP 429 / 5xx: a full connection slot or an overloaded panel.
    case overloaded
    /// HTTP 404: the stream is gone, and retrying will not bring it back.
    case notFound

    init(_ error: EngineError) {
        if error.code == .sourceEnded {
            self = .sourceEnded
            return
        }
        self = switch error.httpFailure {
        case .unauthorized, .forbidden: .unauthorized
        case .tooManyRequests, .serverError: .overloaded
        case .notFound: .notFound
        // 400, any other 4xx, no HTTP status, and classes added later.
        default: .interrupted
        }
    }
}
