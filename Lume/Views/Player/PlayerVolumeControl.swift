//
//  PlayerVolumeControl.swift
//  Lume
//
//  The macOS player's speaker button and its hover slider, shared by the
//  KSPlayer, VLCKit, AVPlayer and LumeEngine overlays. Both leaves read the
//  session's `PlayerVolumeStore` themselves, so a drag re-renders them and not
//  the overlay; the engine views push the store into the engine.
//

import SwiftUI

extension View {
    /// Draws the volume slider above the bottom pill's speaker button. Applied
    /// to the pill itself, outside its glass, and kept in the player's window
    /// rather than a popover so the pointer never leaves the host's hover area.
    @ViewBuilder
    func playerVolumePanelHost(onResetHideTimer: @escaping () -> Void) -> some View {
        #if os(macOS)
            modifier(PlayerVolumePanelHost(onResetHideTimer: onResetHideTimer))
        #else
            self
        #endif
    }
}

/// Draws nothing off macOS, where the system volume is the only one.
struct PlayerVolumeControl: View {
    var onResetHideTimer: () -> Void

    var body: some View {
        #if os(macOS)
            PlayerVolumeButton(onResetHideTimer: onResetHideTimer)
        #endif
    }
}

#if os(macOS)
    private struct PlayerVolumeButton: View {
        var onResetHideTimer: () -> Void

        @Environment(PlayerVolumeStore.self) private var playerVolume: PlayerVolumeStore?
        @Environment(PlayerVolumePanel.self) private var panel: PlayerVolumePanel?

        var body: some View {
            if let playerVolume, !playerVolume.isRoutedExternally {
                let glyph = PlayerVolumeMath.glyph(for: playerVolume.effective)
                let title: LocalizedStringKey = playerVolume.effective <= 0 ? "Unmute" : "Mute"
                Button {
                    playerVolume.toggleMute()
                    onResetHideTimer()
                } label: {
                    Image(systemName: glyph)
                        .symbolReplaceTransition(value: glyph)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title)
                .accessibilityLabel(title)
                .playerVolumeAdjustable(playerVolume, onResetHideTimer: onResetHideTimer)
                .onHover { inside in
                    panel?.setHovering(inside, over: .button)
                    if inside { onResetHideTimer() }
                }
                .anchorPreference(key: PlayerVolumeAnchorKey.self, value: .bounds) { $0 }
                .onDisappear { panel?.dismiss() }
            }
        }
    }

    /// Whether the slider is up. Shared by the button, which opens it, and the
    /// host, which draws it, through the environment.
    @MainActor @Observable
    final class PlayerVolumePanel {
        enum Region { case button, slider }

        private(set) var isPresented = false

        @ObservationIgnored private var hovered: Set<Region> = []
        @ObservationIgnored private var isDragging = false
        @ObservationIgnored private var closeTask: Task<Void, Never>?

        func setHovering(_ inside: Bool, over region: Region) {
            if inside { hovered.insert(region) } else { hovered.remove(region) }
            updatePresentation()
        }

        func setDragging(_ dragging: Bool) {
            isDragging = dragging
            updatePresentation()
        }

        func dismiss() {
            closeTask?.cancel()
            hovered = []
            isDragging = false
            isPresented = false
        }

        private func updatePresentation() {
            closeTask?.cancel()
            if !hovered.isEmpty || isDragging {
                isPresented = true
                return
            }
            // Bridges the gap between the button and the slider.
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.isPresented = false
            }
        }
    }

    private struct PlayerVolumeAnchorKey: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil

        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = value ?? nextValue()
        }
    }

    private struct PlayerVolumePanelHost: ViewModifier {
        let onResetHideTimer: () -> Void

        @State private var panel = PlayerVolumePanel()

        func body(content: Content) -> some View {
            content
                .environment(panel)
                .overlayPreferenceValue(PlayerVolumeAnchorKey.self) { anchor in
                    ZStack {
                        if panel.isPresented, let anchor {
                            GeometryReader { proxy in
                                let button = proxy[anchor]
                                PlayerVolumeSlider(panel: panel, onResetHideTimer: onResetHideTimer)
                                    .position(
                                        x: button.midX,
                                        y: button.minY - PlayerVolumeSlider.gap - PlayerVolumeSlider.size.height / 2
                                    )
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: panel.isPresented)
                }
        }
    }

    private struct PlayerVolumeSlider: View {
        static let size = CGSize(width: 40, height: 140)
        static let gap: CGFloat = 8
        private static let trackWidth: CGFloat = 6
        private static let knobDiameter: CGFloat = 14
        private static let inset: CGFloat = 14

        let panel: PlayerVolumePanel
        var onResetHideTimer: () -> Void

        @Environment(PlayerVolumeStore.self) private var playerVolume: PlayerVolumeStore?

        var body: some View {
            if let playerVolume {
                let level = CGFloat(playerVolume.effective)
                GeometryReader { proxy in
                    let travel = proxy.size.height - Self.knobDiameter
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(width: Self.trackWidth)
                        Capsule()
                            .fill(.white)
                            .frame(width: Self.trackWidth, height: Self.knobDiameter / 2 + travel * level)
                        Circle()
                            .fill(.white)
                            .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .offset(y: -travel * level)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(travel: travel, in: playerVolume))
                }
                .padding(.vertical, Self.inset)
                .frame(width: Self.size.width, height: Self.size.height)
                .glassEffectCompat(.regular, in: Capsule())
                .contentShape(Capsule())
                .onHover { panel.setHovering($0, over: .slider) }
                .accessibilityElement()
                .accessibilityLabel("Volume")
                .playerVolumeAdjustable(playerVolume, onResetHideTimer: onResetHideTimer)
            }
        }

        private func dragGesture(travel: CGFloat, in playerVolume: PlayerVolumeStore) -> some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    panel.setDragging(true)
                    let fromBottom = travel + Self.knobDiameter / 2 - value.location.y
                    playerVolume.setLevel(Float(fromBottom / max(travel, 1)))
                    onResetHideTimer()
                }
                .onEnded { _ in
                    playerVolume.commit()
                    panel.setDragging(false)
                    onResetHideTimer()
                }
        }
    }

    private extension View {
        func playerVolumeAdjustable(
            _ playerVolume: PlayerVolumeStore,
            onResetHideTimer: @escaping () -> Void
        ) -> some View {
            accessibilityValue(Text(Double(playerVolume.effective), format: .percent.precision(.fractionLength(0))))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: playerVolume.step(up: true)
                    case .decrement: playerVolume.step(up: false)
                    @unknown default: return
                    }
                    onResetHideTimer()
                }
        }
    }
#endif
