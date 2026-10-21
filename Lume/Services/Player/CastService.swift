import AVFoundation
import Foundation
import OSLog
#if os(iOS)
    import UIKit
#endif

/// Coordinates "casting" — sending playback to an external device — for the
/// player overlay, independent of which playback engine is active.
///
/// AirPlay is routed natively by AVFoundation, so today this service just
/// observes the audio route and surfaces whether playback is currently leaving
/// the device, which the overlay reads for the Cast affordance's accessibility
/// state. The `CastProvider` seam is where a future Google Cast (Chromecast)
/// integration plugs in without the overlay needing to know which casting
/// ecosystem is in use — see issue #103.
///
/// Per-engine AirPlay reality: only the AVPlayer engine can hand full-screen
/// video to an AirPlay receiver (it enables `allowsExternalPlayback`). KSPlayer
/// and VLCKit render into their own layers, so AirPlay would carry only their
/// audio — so when `isAirPlayActive` flips, `FullScreenPlayerView` drives the
/// stream through the AVPlayer engine for the duration of the cast. The route
/// state tracked here is engine-agnostic because AirPlay always reshapes the
/// shared audio route.
///
/// Screen Mirroring also routes audio over AirPlay, but there the receiver
/// already shows whatever the device draws, so every engine works as is.
/// Forcing AVPlayer there made it hand the stream URL to the Apple TV, which
/// many IPTV streams can't play, leaving only sound. `isAirPlayCasting`
/// excludes a captured screen so mirroring keeps the user's engine.
///
/// macOS has no `AVAudioSession`, so route observation — and with it the
/// engine handoff — doesn't exist there: `isAirPlayActive` stays `false` and
/// AirPlay is available only on the AVPlayer engine, whose overlay binds the
/// route picker to its player directly (see `AirPlayRouteButton`). tvOS is
/// likewise excluded: the Apple TV is itself the AirPlay destination, so its
/// route always looks "external" and the handoff would wrongly pin every
/// stream to AVPlayer, ignoring the user's engine priority.
@MainActor
@Observable
final class CastService {
    static let shared = CastService()

    /// Whether playback is currently routed to an external AirPlay receiver.
    var isAirPlayActive: Bool {
        airPlayRouteName != nil
    }

    /// Display name of the active AirPlay route, when the system reports one.
    private(set) var airPlayRouteName: String?

    /// Whether a screen is being captured: AirPlay Screen Mirroring, or a
    /// screen recording, which the system doesn't tell apart. Always `false`
    /// on visionOS, which has no `UIScreen`.
    private(set) var isScreenCaptured = false

    /// Whether AirPlay is carrying a cast that needs the AVPlayer engine,
    /// rather than mirroring the screen.
    var isAirPlayCasting: Bool {
        Self.isAirPlayCasting(routeName: airPlayRouteName, isScreenCaptured: isScreenCaptured)
    }

    /// A registered casting provider (e.g. a future Chromecast backend). `nil`
    /// until the Google Cast SDK is integrated — see `CastProvider` and #103.
    var castProvider: (any CastProvider)?

    /// Touched from the nonisolated `deinit`; `removeObserver` is thread-safe.
    @ObservationIgnored private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

    private init() {
        refreshAirPlayRoute()
        refreshScreenCapture()
        observeRouteChanges()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// A single output of the current audio route, reduced to the fields the
    /// AirPlay check needs so the matching logic stays unit-testable without a
    /// live `AVAudioSession`.
    struct RouteOutput: Equatable {
        let isAirPlay: Bool
        let name: String
    }

    /// The name of the first AirPlay output among the given route outputs, or
    /// `nil` when none is AirPlay. Pure, so it can be exercised in tests.
    static func activeAirPlayName(in outputs: [RouteOutput]) -> String? {
        outputs.first(where: \.isAirPlay)?.name
    }

    /// Pure, so it can be exercised in tests.
    static func isAirPlayCasting(routeName: String?, isScreenCaptured: Bool) -> Bool {
        routeName != nil && !isScreenCaptured
    }

    private func refreshAirPlayRoute() {
        // tvOS is the AirPlay *destination*, not a device casting elsewhere: its
        // audio route reports an external/AirPlay-style output almost always,
        // which would spuriously force the AVPlayer engine (see the override in
        // FullScreenPlayerView) and ignore the user's engine priority. So route
        // observation — and the engine handoff — is iOS/visionOS only.
        #if os(iOS) || os(visionOS)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
                RouteOutput(isAirPlay: $0.portType == .airPlay, name: $0.portName)
            }
            let name = Self.activeAirPlayName(in: outputs)
            if name != airPlayRouteName {
                airPlayRouteName = name
                Logger.player.log("AirPlay route changed: active=\(name != nil, privacy: .public)")
            }
        #endif
    }

    private func refreshScreenCapture() {
        #if os(iOS)
            let captured = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen }
                .contains(where: \.isCaptured)
            if captured != isScreenCaptured {
                isScreenCaptured = captured
                Logger.player.log("Screen capture changed: captured=\(captured, privacy: .public)")
            }
        #endif
    }

    private func observeRouteChanges() {
        #if os(iOS) || os(visionOS)
            observe(AVAudioSession.routeChangeNotification)
        #endif
        #if os(iOS)
            observe(UIScreen.capturedDidChangeNotification)
            // The service can start before any scene connects, so a launch
            // while already mirroring is only seen once a scene activates.
            observe(UIScene.didActivateNotification)
        #endif
    }

    private func observe(_ name: Notification.Name) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAirPlayRoute()
                self?.refreshScreenCapture()
            }
        })
    }
}

/// A casting backend abstraction. AirPlay is handled natively by AVFoundation
/// and needs no provider; this seam exists for a future Google Cast
/// (Chromecast) integration — see #103. A provider discovers receivers, starts
/// and ends a session for a given `PlayableMedia`, and mirrors transport state
/// back to the overlay so watch-progress / NextUp tracking can follow the cast.
@MainActor
protocol CastProvider: AnyObject {
    /// Human-readable name of the connected receiver, when connected.
    var connectedDeviceName: String? { get }

    /// Whether a cast session is currently active.
    var isCasting: Bool { get }

    /// Begin casting the given media to the selected receiver, seeking the
    /// receiver to `position` seconds so playback resumes where it left off.
    func beginSession(for media: PlayableMedia, startingAt position: TimeInterval)

    /// End the current cast session.
    func endSession()
}
