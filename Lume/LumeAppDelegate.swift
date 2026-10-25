#if os(iOS)
    import UIKit

    /// Exists for hooks with no SwiftUI equivalent: the background
    /// `URLSession` relaunch, the app-wide orientation mask the player narrows
    /// to landscape (`PlayerOrientationLock`), and Google Cast setup, which
    /// must run at launch so the SDK can resume a session the app left running.
    ///
    /// When a download finishes while Lume is suspended or terminated, the system
    /// relaunches the app in the background and calls
    /// `handleEventsForBackgroundURLSession` before delivering the session's
    /// queued events. There is no `App`- or `Scene`-level modifier for this, so a
    /// `UIApplicationDelegate` is the only way to receive it.
    final class LumeAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
        ) -> Bool {
            #if canImport(GoogleCast)
                if !LumeApp.isTestOrPreviewHost {
                    GoogleCastProvider.configure()
                    CastService.shared.castProvider = GoogleCastProvider()
                }
            #endif
            return true
        }

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

        func application(
            _: UIApplication,
            supportedInterfaceOrientationsFor _: UIWindow?
        ) -> UIInterfaceOrientationMask {
            PlayerOrientationLock.supportedOrientations
        }
    }
#endif
