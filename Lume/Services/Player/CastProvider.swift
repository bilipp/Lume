//
//  CastProvider.swift
//  Lume
//
//  The Google Cast provider seam `CastService` drives, and the value types
//  that cross it.
//

import Foundation

/// The receiver app Lume casts to. Swapping in a custom receiver means
/// changing this id and its `NSBonjourServices` entry in Info.plist.
nonisolated enum CastReceiver {
    /// Google's Default Media Receiver (`kGCKDefaultMediaReceiverApplicationID`).
    static let appID = "CC1AD845"
}

/// A Google Cast backend. `GoogleCastProvider` is the only implementation and
/// the only code that touches the SDK; everything else goes through
/// `CastService`. The provider reports changes through `eventHandler` and
/// `CastService` reads its properties back, all on the main actor.
@MainActor
protocol CastProvider: AnyObject {
    /// Set by `CastService` when the provider is registered.
    var eventHandler: ((CastProviderEvent) -> Void)? { get set }

    var devices: [CastDevice] { get }
    var connectionState: CastConnectionState { get }
    /// Name of the receiver connected or being connected to.
    var connectedDeviceName: String? { get }
    var status: CastPlaybackStatus { get }

    /// Discovery doesn't run until asked, so the local-network prompt waits
    /// for the first tap on the Cast button.
    func startDiscovery()
    func stopDiscovery()
    func connect(to device: CastDevice)

    /// Loads `request` on the connected receiver, returning once the receiver
    /// accepts it and throwing `.loadFailed` when it rejects it.
    func load(_ request: CastMediaRequest) async throws(CastError)
    func play()
    func pause()
    func seek(to position: TimeInterval)
    /// Receiver volume, 0...1.
    func setVolume(_ volume: Float)
    /// Leaves the session; `stopReceiver` also stops playback on the receiver.
    func endSession(stopReceiver: Bool)
}

/// What changed in a provider; `CastService` reads the new values back.
nonisolated enum CastProviderEvent: Hashable {
    case devicesChanged
    case connectionChanged
    case statusChanged
    /// The session is gone, for `reason`.
    case sessionEnded(CastSessionEnd.Reason)
}

nonisolated enum CastConnectionState: Hashable {
    case idle
    case connecting
    case connected
}

nonisolated enum CastError: Error, Hashable {
    case notConnected
    case loadFailed
    /// A newer load replaced this one before the receiver answered. Not a
    /// failure: the newer load's caller owns the outcome.
    case superseded
}

/// Whether the open player's stream can go to a Cast receiver.
nonisolated enum PlayerCastability: Hashable {
    case castable
    case unsupported(CastStreamResolver.Reason)

    /// Why the device sheet's receivers are disabled, if they are.
    var unsupportedReason: CastStreamResolver.Reason? {
        if case let .unsupported(reason) = self { reason } else { nil }
    }
}

/// Where playback currently leaves the device.
nonisolated enum CastRoute: Hashable {
    case local
    case airPlay(String)
    case connectingChromecast(deviceName: String?)
    case chromecast(deviceName: String?)
}

/// A discovered Cast receiver.
nonisolated struct CastDevice: Hashable, Identifiable {
    enum Kind: Hashable {
        case television
        case speaker
        case speakerGroup
        case other
    }

    let id: String
    let name: String
    let modelName: String?
    let kind: Kind
}

nonisolated extension CastDevice {
    /// The name shown for a receiver that doesn't report one.
    static let unnamedName = LocalizedStringResource(
        "player.cast.device.unnamed",
        defaultValue: "Cast Device",
        comment: "Player › Cast sheet: name shown for a Chromecast that doesn't report one."
    )
}

nonisolated extension CastDevice.Kind {
    var systemImage: String {
        switch self {
        case .television, .other: "tv"
        case .speaker: "hifispeaker"
        case .speakerGroup: "hifispeaker.2"
        }
    }
}

/// The receiver's media status, reduced to what Lume shows and tracks.
nonisolated struct CastPlaybackStatus: Hashable {
    /// Why the receiver went idle.
    enum IdleReason: Hashable {
        case finished
        case stopped
        case error
        /// Replaced by another load.
        case interrupted
    }

    /// Whether the receiver has any media loaded.
    var hasMedia: Bool
    var position: TimeInterval
    /// `nil` for live streams and before the receiver knows it.
    var duration: TimeInterval?
    var isPlaying: Bool
    var isBuffering: Bool
    /// Receiver volume, 0...1.
    var volume: Float
    /// Set once the receiver is idle; `nil` while media is loaded.
    var idleReason: IdleReason?
    /// The receiver's own metadata, for a session the SDK resumed without
    /// Lume knowing what it plays.
    var title: String?
    var subtitle: String?
    var posterURL: URL?

    static let idle = CastPlaybackStatus(
        hasMedia: false, position: 0, duration: nil, isPlaying: false,
        isBuffering: false, volume: 1, idleReason: nil
    )
}

nonisolated extension CastPlaybackStatus.IdleReason {
    /// The session-end reason this idle reason means, or `nil` when the item
    /// was merely replaced by a new load.
    var sessionEndReason: CastSessionEnd.Reason? {
        switch self {
        case .finished: .finished
        case .stopped: .stopped
        case .error: .error
        case .interrupted: nil
        }
    }
}

/// The receiver stopped playing media Lume tracked.
nonisolated struct CastSessionEnd: Hashable {
    enum Reason: Hashable {
        case finished
        /// Stopped by the user, from Lume or another sender.
        case stopped
        /// The receiver failed to play the media.
        case error
        /// The connection to the receiver was lost.
        case disconnected
    }

    let reason: Reason
    /// The last position the receiver reported while playing.
    let lastPosition: TimeInterval
    let duration: TimeInterval?
    /// What Lume loaded; `nil` for a session resumed at launch.
    let request: CastMediaRequest?
}
