#if os(iOS)
    import UIKit

    /// Exists for one thing: the background `URLSession` relaunch hook, which has
    /// no SwiftUI equivalent.
    ///
    /// When a download finishes while Lume is suspended or terminated, the system
    /// relaunches the app in the background and calls
    /// `handleEventsForBackgroundURLSession` before delivering the session's
    /// queued events. There is no `App`- or `Scene`-level modifier for this, so a
    /// `UIApplicationDelegate` is the only way to receive it.
    final class LumeAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _: UIApplication,
            handleEventsForBackgroundURLSession identifier: String,
            completionHandler: @escaping () -> Void
        ) {
            // Touching `shared` here is load-bearing, not incidental: it rebuilds
            // the session object the queued events are addressed to. See
            // `DownloadManager.handleBackgroundSessionEvents(identifier:completionHandler:)`.
            DownloadManager.shared.handleBackgroundSessionEvents(
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }
#endif
