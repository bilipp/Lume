import Foundation
import LumeCloudKit

/// Why an account flow of `LumeCloudBackend` failed before or besides a server
/// error. Server errors (`LumeCloudError`: `.signupClosed`, `.rateLimited`,
/// `.transport`, …) pass through unchanged.
nonisolated enum LumeCloudAccountError: Error, Equatable {
    /// The backend is inert (`-ui-testing`, previews): no network at all.
    case unavailable
    /// The flow needs an account this device hasn't joined.
    case notJoined
    /// This device already syncs through an account; leave it first.
    case alreadyJoined
    /// The keychain refused to store the identity, so joining would lose the key.
    case keychainUnavailable
    /// Not exactly six digits.
    case invalidPairingCode
    /// The code expired or is unknown to the server.
    case pairingExpired
    /// The sealed grant didn't open: a wrong code or tampered data.
    case pairingFailed
    /// The grant names another server than this build's (a debug and a release
    /// build never share an account).
    case serverMismatch
    /// This device leaves through `leave()`, never by revoking itself.
    case cannotRevokeCurrentDevice
    /// Not a recovery key: wrong length or characters.
    case invalidRecoveryKey
    /// The recovery key's check character doesn't match: most likely a typo.
    case recoveryKeyTypo
    /// A well-formed recovery key no account accepts.
    case wrongRecoveryKey
}

/// How an account ended under a joined device, reported through
/// `LumeCloudBackend.onAccountEnded`. Local data is kept either way.
nonisolated enum LumeCloudAccountEnd: Equatable {
    /// 404 `account_deleted`: every Apple device leaves; the keychain identity is cleared.
    case accountDeleted
    /// 401 `device_revoked`: only this device leaves.
    case deviceRevoked
}

/// The code a new device shows while it waits to be added. Never log it.
nonisolated struct LumeCloudPairingCode: Equatable {
    var code: String
    var expiresAt: Date

    /// The QR payload: a deep link that opens the add-device flow with the code
    /// filled in.
    var deepLink: URL {
        var components = URLComponents()
        components.scheme = "lume"
        components.host = "cloud"
        components.path = "/pair"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url!
    }
}

/// A device waiting to be added, as the server describes it, shown for
/// confirmation before the account key is sealed to it.
nonisolated struct LumeCloudPendingDevice: Equatable {
    var code: String
    var name: String
    /// The server's platform token (`ios`, `tvos`, `android`, …); open-ended.
    var platform: String
    var publicKey: String
}

/// One device of the account, for the device list.
nonisolated struct LumeCloudDeviceInfo: Equatable, Identifiable {
    var id: UUID
    var name: String
    /// The server's platform token (`ios`, `tvos`, `android`, …); open-ended.
    var platform: String
    var createdAt: Date
    var lastSeen: Date
    var isCurrent: Bool
}

/// How a server platform token reads in the UI. The token list is open, so an
/// unknown one reads generically.
nonisolated enum LumeCloudPlatformName {
    static func displayName(for platform: String) -> String {
        switch LumeCloudPlatform(rawValue: platform.lowercased()) {
        case .iOS: "iOS"
        case .tvOS: "tvOS"
        case .macOS: "macOS"
        case .visionOS: "visionOS"
        case .android: "Android"
        case .androidTV: "Android TV"
        default: String(localized: "Other device")
        }
    }

    /// An unknown token gets a generic symbol.
    static func symbolName(for platform: String) -> String {
        switch LumeCloudPlatform(rawValue: platform.lowercased()) {
        case .iOS: "iphone"
        case .tvOS: "appletv"
        case .macOS: "laptopcomputer"
        case .visionOS: "visionpro"
        case .android: "candybarphone"
        case .androidTV: "tv"
        default: "questionmark.square.dashed"
        }
    }
}
