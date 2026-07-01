import AVFoundation
import Foundation
import OSLog

#if os(iOS) && canImport(GoogleCast)
    import GoogleCast
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
@MainActor
@Observable
final class CastService {
    static let shared = CastService()

    /// Whether playback is currently routed to an external AirPlay receiver.
    private(set) var isAirPlayActive = false

    /// Display name of the active AirPlay route, when the system reports one.
    private(set) var airPlayRouteName: String?

    /// A registered casting provider (e.g. a future Chromecast backend). `nil`
    /// until the Google Cast SDK is integrated — see `CastProvider` and #103.
    var castProvider: (any CastProvider)?

    /// Touched from the nonisolated `deinit`; `removeObserver` is thread-safe.
    private nonisolated(unsafe) var routeObserver: (any NSObjectProtocol)?

    private init() {
        refreshAirPlayRoute()
        observeRouteChanges()
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
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

    /// Configure the Google Cast SDK and register the Chromecast provider against
    /// the `castProvider` seam. Call once at app launch. This is a no-op unless
    /// the `GoogleCast` product is linked (the SDK is not bundled — see
    /// `Docs/Chromecast.md`), so it is safe to call unconditionally.
    func configureGoogleCast() {
        #if os(iOS) && canImport(GoogleCast)
            let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
            let options = GCKCastOptions(discoveryCriteria: criteria)
            GCKCastContext.setSharedInstanceWith(options)
            castProvider = GoogleCastProvider()
            Logger.player.log("Chromecast: Cast context configured")
        #endif
    }

    private func refreshAirPlayRoute() {
        #if os(iOS) || os(tvOS) || os(visionOS)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
                RouteOutput(isAirPlay: $0.portType == .airPlay, name: $0.portName)
            }
            let name = Self.activeAirPlayName(in: outputs)
            if name != airPlayRouteName {
                let active = name != nil
                airPlayRouteName = name
                isAirPlayActive = active
                Logger.player.log("AirPlay route changed: active=\(active, privacy: .public)")
            }
        #endif
    }

    private func observeRouteChanges() {
        #if os(iOS) || os(tvOS) || os(visionOS)
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAirPlayRoute() }
            }
        #endif
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
