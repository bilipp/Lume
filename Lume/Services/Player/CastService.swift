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

    /// The registered casting provider (Chromecast, via the bundled Google Cast
    /// SDK on iOS). `nil` on the platforms the SDK doesn't support — see
    /// `CastProvider`, `configureGoogleCast()` and #103.
    var castProvider: (any CastProvider)?

    /// Whether the registered provider has an active cast session. Mirrored
    /// from the provider (which is not `@Observable`) so SwiftUI can react —
    /// `FullScreenPlayerView` loads the current stream onto the receiver when
    /// this flips true.
    private(set) var isProviderCasting = false

    /// True when the Google Cast SDK is linked into this build (iOS only).
    /// Lets tests assert the provider seam without re-deriving the platform
    /// gate themselves.
    nonisolated static var isGoogleCastAvailable: Bool {
        #if os(iOS) && canImport(GoogleCast)
            true
        #else
            false
        #endif
    }

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
    /// the `castProvider` seam. Call once at app launch. This is a no-op on the
    /// platforms where the (iOS-only) Cast SDK isn't linked — see
    /// `Docs/Chromecast.md` — so it is safe to call unconditionally.
    func configureGoogleCast() {
        #if os(iOS) && canImport(GoogleCast)
            let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
            let options = GCKCastOptions(discoveryCriteria: criteria)
            GCKCastContext.setSharedInstanceWith(options)
            let provider = GoogleCastProvider()
            provider.onCastingChanged = { [weak self] casting in
                self?.isProviderCasting = casting
            }
            castProvider = provider
            Logger.player.log("Chromecast: Cast context configured")
        #endif
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

    private func observeRouteChanges() {
        #if os(iOS) || os(visionOS)
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
/// and needs no provider; this seam is where the Google Cast (Chromecast)
/// backend plugs in — see #103. A provider discovers receivers, starts
/// and ends a session for a given `PlayableMedia`, and exposes the receiver's
/// transport so the casting UI can drive it and watch-progress / NextUp
/// tracking can follow the cast (see `ChromecastPlaybackView`).
@MainActor
protocol CastProvider: AnyObject {
    /// Human-readable name of the connected receiver, when connected.
    var connectedDeviceName: String? { get }

    /// Whether a cast session is currently active.
    var isCasting: Bool { get }

    /// Reports `isCasting` flips so `CastService` can mirror them into its
    /// observable `isProviderCasting`. Set by `CastService` at registration.
    var onCastingChanged: ((Bool) -> Void)? { get set }

    /// Begin casting the given media to the selected receiver, seeking the
    /// receiver to `position` seconds so playback resumes where it left off.
    /// Loading the same URL again is a no-op, so callers can invoke this from
    /// every "media or session may have changed" edge without restarting the
    /// receiver's stream.
    func beginSession(for media: PlayableMedia, startingAt position: TimeInterval)

    /// End the current cast session.
    func endSession()

    /// The receiver's playhead in seconds, interpolated between status updates.
    /// `0` while nothing is loaded. Polled by the casting UI — the Cast SDK
    /// pushes media status only on change, not per tick.
    var approximatePosition: TimeInterval { get }

    /// The loaded stream's duration in seconds, or `0` when unknown (live, or
    /// nothing loaded yet).
    var streamDuration: TimeInterval { get }

    /// Whether the receiver is currently playing (as opposed to paused, idle,
    /// or still loading).
    var isReceiverPlaying: Bool { get }

    /// Resume playback on the receiver.
    func play()

    /// Pause playback on the receiver.
    func pause()

    /// Seek the receiver to an absolute position in seconds.
    func seek(to seconds: TimeInterval)
}
