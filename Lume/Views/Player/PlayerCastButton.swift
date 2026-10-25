//
//  PlayerCastButton.swift
//  Lume
//
//  The Cast affordance in the player overlays' top bar. On iPhone and iPad it
//  opens Lume's device sheet (Chromecast receivers plus an AirPlay row); on
//  macOS and visionOS it stays the plain AirPlay route picker, bound to the
//  AVPlayer engine's player as before. tvOS has no Cast affordance.
//

#if !os(tvOS)
    import AVKit
    import SwiftUI

    struct PlayerCastButton: View {
        /// The AVPlayer the macOS route picker drives. Unused on iOS, where
        /// AirPlay routes system-wide.
        var player: AVPlayer?

        #if os(iOS)
            @Environment(\.showCastDevices) private var showCastDevices
            @State private var cast = CastService.shared
        #endif

        var body: some View {
            #if os(iOS)
                if let showCastDevices {
                    Button(action: showCastDevices) {
                        Image(systemName: glyph)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.pulse, isActive: cast.chromecastConnection == .connecting)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .glassEffectCompat(.regularInteractive, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(Self.label))
                    .accessibilityValue(routeName ?? "")
                } else {
                    // Outside the full-screen player nothing would start a
                    // Chromecast session, so only AirPlay is on offer.
                    AirPlayRouteButton(player: player)
                }
            #else
                AirPlayRouteButton(player: player)
            #endif
        }

        #if os(iOS)
            private var glyph: String {
                cast.route == .local ? "tv.badge.wifi" : "tv.badge.wifi.fill"
            }

            private var routeName: String? {
                switch cast.route {
                case .local: nil
                case let .airPlay(name): name
                case let .chromecast(name):
                    name ?? String(localized: "Connected")
                case let .connectingChromecast(name):
                    name.map { String(localized: CastDeviceSheet.connectingTitle(deviceName: $0)) }
                        ?? String(localized: "Connecting…")
                }
            }

            private static let label = LocalizedStringResource(
                "player.cast.button",
                defaultValue: "Cast",
                comment: "Player › Controls: accessibility label of the button that sends playback to a Chromecast or AirPlay device."
            )
        #endif
    }

    #if os(iOS)
        extension EnvironmentValues {
            /// Opens the Cast device sheet, installed by the full-screen player.
            @Entry var showCastDevices: (() -> Void)?
        }
    #endif
#endif
