import SwiftUI

// The Chromecast affordance for the player overlay. It mirrors `AirPlayRoute
// Button`'s glass-circle styling but is backed by the Google Cast SDK's
// `GCKUICastButton`, which handles device discovery and session start/stop.
//
// The Google Cast SDK is an iOS-only third-party dependency that is **not
// bundled** here (see `Docs/Chromecast.md`). Until it is linked — and on every
// non-iOS platform — this renders nothing, so the overlays can place it
// unconditionally next to the AirPlay button.

#if os(iOS) && canImport(GoogleCast)
    import GoogleCast
    import UIKit

    struct ChromecastButton: View {
        var body: some View {
            CastButtonRepresentable()
                .frame(width: 44, height: 44)
                .glassEffectCompat(.regularInteractive, in: Circle())
                .accessibilityLabel("Chromecast")
        }
    }

    private struct CastButtonRepresentable: UIViewRepresentable {
        func makeUIView(context _: Context) -> GCKUICastButton {
            let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            button.tintColor = .white
            return button
        }

        func updateUIView(_: GCKUICastButton, context _: Context) {}
    }
#else
    struct ChromecastButton: View {
        var body: some View {
            EmptyView()
        }
    }
#endif
