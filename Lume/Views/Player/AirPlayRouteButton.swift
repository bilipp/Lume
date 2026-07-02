#if !os(tvOS)
    import AVKit
    import SwiftUI

    #if canImport(UIKit)
        import UIKit
    #elseif canImport(AppKit)
        import AppKit
    #endif

    /// The Cast affordance in the player overlay: an `AVRoutePickerView` styled
    /// to match the overlay's glass circle buttons. Tapping it presents the
    /// system AirPlay route picker.
    ///
    /// Picking a receiver drives full-screen video: the AVPlayer engine enables
    /// `allowsExternalPlayback`, and on the KSPlayer/VLCKit engines (which render
    /// into their own layers) `FullScreenPlayerView` hands the stream to AVPlayer
    /// for the cast. See `CastService` and #103.
    struct AirPlayRouteButton: View {
        /// The AVPlayer the route picker drives on macOS, where the picker is
        /// bound to a specific player. `nil` on the engines that don't expose an
        /// `AVPlayer` (KSPlayer / VLCKit) and unused on iOS / visionOS, which
        /// route system-wide.
        var player: AVPlayer?

        /// Observed so the button reflects the live route in its accessibility
        /// value; the picker itself shows the active tint.
        @State private var cast = CastService.shared

        var body: some View {
            RoutePicker(player: player)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regularInteractive, in: Circle())
                .accessibilityLabel("AirPlay")
                .accessibilityValue(cast.isAirPlayActive ? (cast.airPlayRouteName ?? "Connected") : "")
        }
    }

    #if canImport(UIKit)
        private struct RoutePicker: UIViewRepresentable {
            var player: AVPlayer?

            func makeUIView(context _: Context) -> AVRoutePickerView {
                let picker = AVRoutePickerView()
                picker.backgroundColor = .clear
                picker.tintColor = .white
                picker.activeTintColor = UIColor(named: "AccentColor") ?? .systemBlue
                // Surface video-capable receivers (Apple TV, AirPlay TVs) first.
                picker.prioritizesVideoDevices = true
                return picker
            }

            func updateUIView(_: AVRoutePickerView, context _: Context) {}
        }

    #elseif canImport(AppKit)
        private struct RoutePicker: NSViewRepresentable {
            var player: AVPlayer?

            func makeNSView(context _: Context) -> AVRoutePickerView {
                let picker = AVRoutePickerView()
                picker.isRoutePickerButtonBordered = false
                picker.player = player
                picker.setRoutePickerButtonColor(.white, for: .normal)
                return picker
            }

            func updateNSView(_ nsView: AVRoutePickerView, context _: Context) {
                nsView.player = player
            }
        }
    #endif
#endif
