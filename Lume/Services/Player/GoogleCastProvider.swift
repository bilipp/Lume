import Foundation
import OSLog

// Chromecast is delivered through the Google Cast SDK (v4.8.4), an iOS-only
// dependency bundled at `Vendor/GoogleCast` and linked with `platformFilter =
// ios` (see `Docs/Chromecast.md`). This file is gated behind
// `os(iOS) && canImport(GoogleCast)` so the macOS/tvOS/visionOS builds never
// compile it. `CastService.configureGoogleCast()` registers this provider on the
// `CastProvider` seam and the overlay's Chromecast button comes to life.

#if os(iOS) && canImport(GoogleCast)
    import GoogleCast

    /// Bridges the Google Cast SDK to the engine-agnostic `CastProvider` seam.
    ///
    /// Device discovery and session start/stop are driven by the system
    /// `GCKUICastButton` (see `ChromecastButton`); this type listens for the
    /// resulting session, loads the current `PlayableMedia` onto the receiver,
    /// and exposes the receiver's transport (play/pause/seek + polled
    /// position/state) for `ChromecastPlaybackView`, which takes the local
    /// engine's place while the session is active (#103).
    @MainActor
    final class GoogleCastProvider: NSObject, CastProvider {
        /// Reports session start/end. `CastService` mirrors this into its
        /// observable `isProviderCasting` so the player UI can react (this
        /// class is not `@Observable`).
        var onCastingChanged: ((Bool) -> Void)?

        /// Reports a stream the receiver wouldn't play. Two things can go wrong
        /// and both land here: the `loadMedia` request itself is rejected (bad
        /// MIME type, unreachable URL), or it is accepted and the receiver then
        /// errors out while starting (CORS refusal on an HLS manifest, a codec
        /// it can't decode). Neither surfaces without asking, which is why
        /// this class keeps both a request delegate and a media-status listener.
        var onFailure: ((CastFailure) -> Void)?

        private(set) var isCasting = false {
            didSet {
                if isCasting != oldValue {
                    onCastingChanged?(isCasting)
                }
            }
        }

        var connectedDeviceName: String? {
            sessionManager.currentCastSession?.device.friendlyName
        }

        /// Media queued to load as soon as a session is available — set when the
        /// user starts casting before a receiver has finished connecting.
        private var pendingMedia: (media: PlayableMedia, position: TimeInterval)?

        /// URL of the stream this provider last loaded onto the current session,
        /// so `beginSession` can no-op when asked to cast what is already
        /// playing (the host re-invokes it on every "may have changed" edge).
        private var loadedURL: URL?

        /// The in-flight `loadMedia` request. Held so its delegate callbacks
        /// arrive — `GCKRequest.delegate` is weak and the request is otherwise
        /// unowned once `loadMedia` returns.
        private var loadRequest: GCKRequest?

        /// Guards against reporting the same stream's failure twice: a rejected
        /// load and the receiver's idle-with-error status can both fire for one
        /// attempt, and the host would otherwise be told twice.
        private var failureReportedForURL: URL?

        private var sessionManager: GCKSessionManager {
            GCKCastContext.sharedInstance().sessionManager
        }

        private var remoteMediaClient: GCKRemoteMediaClient? {
            sessionManager.currentCastSession?.remoteMediaClient
        }

        override init() {
            super.init()
            sessionManager.add(self)
        }

        // No `deinit` unregistration: `deinit` is nonisolated, and detaching a
        // main-actor-isolated conformance from there is an error under the Swift 6
        // language mode. It would also be dead code — `CastService.shared` holds
        // this provider for the life of the process, so it is never deallocated.
        // If that ever changes, add an explicit `@MainActor` teardown the owner
        // calls before releasing it.

        // MARK: - CastProvider

        func beginSession(for media: PlayableMedia, startingAt position: TimeInterval) {
            if let client = remoteMediaClient {
                guard media.url != loadedURL else { return }
                load(media, at: position, on: client)
            } else {
                // No receiver yet — remember the media and load once a session
                // starts (the user is mid-connect via the cast button).
                pendingMedia = (media, position)
            }
        }

        func endSession() {
            pendingMedia = nil
            sessionManager.endSessionAndStopCasting(true)
        }

        // MARK: - Transport

        var approximatePosition: TimeInterval {
            guard let client = remoteMediaClient, client.mediaStatus != nil else { return 0 }
            let position = client.approximateStreamPosition()
            return position.isFinite ? max(position, 0) : 0
        }

        var streamDuration: TimeInterval {
            let duration = remoteMediaClient?.mediaStatus?.mediaInformation?.streamDuration ?? 0
            return duration.isFinite ? max(duration, 0) : 0
        }

        var isReceiverPlaying: Bool {
            // Buffering/loading count as playing: the receiver will resume by
            // itself, so the button should keep offering "pause" rather than
            // flickering to "play" on every rebuffer.
            switch remoteMediaClient?.mediaStatus?.playerState {
            case .playing, .buffering, .loading: true
            default: false
            }
        }

        func play() {
            remoteMediaClient?.play()
        }

        func pause() {
            remoteMediaClient?.pause()
        }

        func seek(to seconds: TimeInterval) {
            let options = GCKMediaSeekOptions()
            options.interval = seconds
            options.resumeState = .unchanged
            remoteMediaClient?.seek(with: options)
        }

        // MARK: - Loading

        private func load(_ media: PlayableMedia, at position: TimeInterval, on client: GCKRemoteMediaClient) {
            // Defence in depth: the host gates on this too, but a provider that
            // silently ships a `file://` download to a TV is the exact failure
            // this whole path exists to remove.
            let verdict = CastCompatibility.evaluate(media.url)
            guard case let .castable(contentType) = verdict else {
                report(.init(url: media.url, detail: "rejected before load: \(verdict)"))
                return
            }

            let metadata = GCKMediaMetadata(metadataType: media.isLive ? .generic : .movie)
            metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
            if let subtitle = media.subtitle, !subtitle.isEmpty {
                metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle)
            }
            if let posterURL = media.posterURL {
                metadata.addImage(GCKImage(url: posterURL, width: 480, height: 720))
            }

            let infoBuilder = GCKMediaInformationBuilder(contentURL: media.url)
            infoBuilder.streamType = media.isLive ? .live : .buffered
            // Left unset for an unrecognised container so the receiver sniffs it
            // rather than trusting a guess (see `CastCompatibility`).
            if let contentType {
                infoBuilder.contentType = contentType
            }
            infoBuilder.metadata = metadata

            let requestBuilder = GCKMediaLoadRequestDataBuilder()
            requestBuilder.mediaInformation = infoBuilder.build()
            requestBuilder.startTime = media.isLive ? kGCKInvalidTimeInterval : position

            loadedURL = media.url
            failureReportedForURL = nil
            let request = client.loadMedia(with: requestBuilder.build())
            request.delegate = self
            loadRequest = request
            Logger.player.log("Chromecast: loading media live=\(media.isLive, privacy: .public) type=\(contentType ?? "sniff", privacy: .public)")
        }

        /// Pass a failure up once per attempt.
        private func report(_ failure: CastFailure) {
            guard failureReportedForURL != failure.url else { return }
            failureReportedForURL = failure.url
            Logger.player.error("Chromecast: \(failure.detail, privacy: .public)")
            onFailure?(failure)
        }
    }

    // MARK: - GCKRequestDelegate

    extension GoogleCastProvider: GCKRequestDelegate {
        func request(_: GCKRequest, didFailWithError error: GCKError) {
            guard let url = loadedURL else { return }
            report(.init(url: url, detail: "load request failed: \(error.localizedDescription)"))
        }

        func request(_: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
            // A replaced request is normal (the viewer switched titles mid-cast);
            // only a cancellation with nothing to show for it is worth reporting.
            guard abortReason != .replaced, let url = loadedURL else { return }
            report(.init(url: url, detail: "load request aborted: \(abortReason.rawValue)"))
        }
    }

    // MARK: - GCKRemoteMediaClientListener

    extension GoogleCastProvider: GCKRemoteMediaClientListener {
        func remoteMediaClient(_: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
            // The receiver accepts the load, tries to start, and gives up — this
            // is where a CORS refusal on an HLS manifest or an undecodable codec
            // lands. `.finished` is a normal end of stream, not a failure.
            guard let mediaStatus,
                  mediaStatus.playerState == .idle,
                  mediaStatus.idleReason == .error,
                  let url = loadedURL
            else { return }
            report(.init(url: url, detail: "receiver went idle with an error"))
        }
    }

    // MARK: - GCKSessionManagerListener

    extension GoogleCastProvider: GCKSessionManagerListener {
        func sessionManager(_: GCKSessionManager, didStart session: GCKCastSession) {
            loadedURL = nil
            failureReportedForURL = nil
            // Per-session client, so the status listener has to be re-attached
            // every time rather than once at init.
            session.remoteMediaClient?.add(self)
            isCasting = true
            Logger.player.log("Chromecast: session started")
            if let pending = pendingMedia, let client = session.remoteMediaClient {
                load(pending.media, at: pending.position, on: client)
                pendingMedia = nil
            }
        }

        func sessionManager(_: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
            session.remoteMediaClient?.add(self)
            isCasting = true
        }

        func sessionManager(_: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
            session.remoteMediaClient?.remove(self)
            loadedURL = nil
            pendingMedia = nil
            loadRequest = nil
            failureReportedForURL = nil
            isCasting = false
            if let error {
                Logger.player.error("Chromecast: session ended with error: \(error.localizedDescription, privacy: .public)")
            }
        }

        func sessionManager(_: GCKSessionManager, didFailToStart _: GCKCastSession, withError error: Error) {
            // The connect attempt died — don't leave the queued media around to
            // auto-load onto some later, unrelated session.
            loadedURL = nil
            pendingMedia = nil
            loadRequest = nil
            failureReportedForURL = nil
            isCasting = false
            Logger.player.error("Chromecast: session failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }
#endif
