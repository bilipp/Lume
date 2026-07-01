import Foundation
import OSLog

// Chromecast is delivered through the Google Cast SDK (v4.8.4), an iOS-only
// dependency bundled at `Vendor/GoogleCast` and linked with `platformFilter =
// ios` (see `Docs/Chromecast.md`). This file is gated behind
// `os(iOS) && canImport(GoogleCast)` so the macOS/tvOS/visionOS builds never
// compile it. `CastService.configureGoogleCast()` registers this provider on the
// `CastProvider` seam and the overlay's Chromecast button comes to life.
//
// Verified to build/link/embed on the iOS simulator; casting to a physical
// receiver and full transport/watch-progress bridging remain (see the doc).

#if os(iOS) && canImport(GoogleCast)
    import GoogleCast

    /// Bridges the Google Cast SDK to the engine-agnostic `CastProvider` seam.
    ///
    /// Device discovery and session start/stop are driven by the system
    /// `GCKUICastButton` (see `ChromecastButton`); this type listens for the
    /// resulting session, loads the current `PlayableMedia` onto the receiver,
    /// and mirrors the receiver's transport state back out via `onProgress`
    /// so watch-progress / NextUp tracking can follow the cast (#103).
    @MainActor
    final class GoogleCastProvider: NSObject, CastProvider {
        /// Reports `(currentTime, duration)` from the receiver as it plays, so
        /// the host can keep recording watch progress while casting. Wired by
        /// `CastService`.
        var onProgress: ((TimeInterval, TimeInterval) -> Void)?

        private(set) var isCasting = false

        var connectedDeviceName: String? {
            sessionManager.currentCastSession?.device.friendlyName
        }

        /// Media queued to load as soon as a session is available — set when the
        /// user starts casting before a receiver has finished connecting.
        private var pendingMedia: (media: PlayableMedia, position: TimeInterval)?

        private var sessionManager: GCKSessionManager {
            GCKCastContext.sharedInstance().sessionManager
        }

        override init() {
            super.init()
            sessionManager.add(self)
        }

        deinit {
            // `GCKCastContext` is a shared singleton; drop our listener so a
            // re-created provider doesn't double-handle session callbacks.
            GCKCastContext.sharedInstance().sessionManager.remove(self)
        }

        // MARK: - CastProvider

        func beginSession(for media: PlayableMedia, startingAt position: TimeInterval) {
            if let client = sessionManager.currentCastSession?.remoteMediaClient {
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

        // MARK: - Transport (used by the overlay once cast transport is wired)

        func play() {
            sessionManager.currentCastSession?.remoteMediaClient?.play()
        }

        func pause() {
            sessionManager.currentCastSession?.remoteMediaClient?.pause()
        }

        func seek(to seconds: TimeInterval) {
            let options = GCKMediaSeekOptions()
            options.interval = seconds
            options.resumeState = .play
            sessionManager.currentCastSession?.remoteMediaClient?.seek(with: options)
        }

        // MARK: - Loading

        private func load(_ media: PlayableMedia, at position: TimeInterval, on client: GCKRemoteMediaClient) {
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
            infoBuilder.contentType = Self.contentType(for: media.url)
            infoBuilder.metadata = metadata

            let requestBuilder = GCKMediaLoadRequestDataBuilder()
            requestBuilder.mediaInformation = infoBuilder.build()
            requestBuilder.startTime = media.isLive ? kGCKInvalidTimeInterval : position

            client.add(self)
            client.loadMedia(with: requestBuilder.build())
            Logger.player.log("Chromecast: loading media live=\(media.isLive, privacy: .public)")
        }

        /// Best-effort MIME type from the URL extension; HLS is the common IPTV
        /// case, so default to it when the container is unknown.
        private static func contentType(for url: URL) -> String {
            switch url.pathExtension.lowercased() {
            case "mp4", "m4v": "video/mp4"
            case "mkv": "video/x-matroska"
            case "ts": "video/mp2t"
            default: "application/x-mpegurl"
            }
        }
    }

    // MARK: - GCKSessionManagerListener

    extension GoogleCastProvider: GCKSessionManagerListener {
        func sessionManager(_: GCKSessionManager, didStart session: GCKCastSession) {
            isCasting = true
            Logger.player.log("Chromecast: session started")
            if let pending = pendingMedia, let client = session.remoteMediaClient {
                load(pending.media, at: pending.position, on: client)
                pendingMedia = nil
            }
        }

        func sessionManager(_: GCKSessionManager, didResumeCastSession _: GCKCastSession) {
            isCasting = true
        }

        func sessionManager(_: GCKSessionManager, didEnd _: GCKCastSession, withError error: Error?) {
            isCasting = false
            if let error {
                Logger.player.error("Chromecast: session ended with error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - GCKRemoteMediaClientListener

    extension GoogleCastProvider: GCKRemoteMediaClientListener {
        func remoteMediaClient(_: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
            guard let mediaStatus else { return }
            let duration = mediaStatus.mediaInformation?.streamDuration ?? 0
            onProgress?(mediaStatus.streamPosition, duration)
        }
    }
#endif
