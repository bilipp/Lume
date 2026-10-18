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
    /// `allowsExternalPlayback`, and on iOS / visionOS the KSPlayer/VLCKit
    /// engines (which render into their own layers) get the stream handed to
    /// AVPlayer by `FullScreenPlayerView`. See `CastService` and #103.
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
            // On macOS the picker routes a *specific* AVPlayer, and with no
            // AVAudioSession there is no route observation to drive the
            // KSPlayer/VLCKit → AVPlayer handoff either — so without a player
            // the button would be inert. Show it only on the AVPlayer engine.
            #if os(macOS)
                if player != nil { picker }
            #else
                picker
            #endif
        }

        private var picker: some View {
            AirPlayRoutePicker(player: player)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regularInteractive, in: Circle())
                .accessibilityLabel("AirPlay")
                .accessibilityValue(cast.isAirPlayActive ? (cast.airPlayRouteName ?? String(localized: "Connected")) : "")
        }
    }

    #if canImport(UIKit)
        /// The system AirPlay route picker. With a `rowLabel` it draws no icon
        /// and is only the tap target over a row that draws its own label;
        /// VoiceOver reads it as one button with that label.
        struct AirPlayRoutePicker: UIViewRepresentable {
            var player: AVPlayer?
            var rowLabel: String?

            func makeUIView(context _: Context) -> AVRoutePickerView {
                let picker = AVRoutePickerView()
                picker.backgroundColor = .clear
                picker.tintColor = rowLabel == nil ? .white : .clear
                picker.activeTintColor = rowLabel == nil ? UIColor(named: "AccentColor") ?? .systemBlue : .clear
                if let rowLabel {
                    picker.isAccessibilityElement = true
                    picker.accessibilityLabel = rowLabel
                    picker.accessibilityTraits = .button
                }
                // Surface video-capable receivers (Apple TV, AirPlay TVs) first.
                picker.prioritizesVideoDevices = true
                return picker
            }

            func updateUIView(_: AVRoutePickerView, context _: Context) {}
        }

    #elseif canImport(AppKit)
        private struct AirPlayRoutePicker: NSViewRepresentable {
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
