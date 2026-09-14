//
//  PlayerItemNavButtons.swift
//  Lume
//
//  The previous / next transport control that flanks play-pause in every
//  non-tvOS engine overlay: the surrounding episodes of a series, or the
//  channels either side of a live one. Authored once because all four engines
//  mount it — adopting it in three of them would make the control vanish the
//  moment playback fell back to the fourth.
//
//  tvOS drives the same swap from the Siri Remote instead and gains no
//  on-screen channel buttons, so this whole file is gated out there.
//

import SwiftUI

#if !os(tvOS)

    /// One end of the transport pair. Two of these bracket the play/pause
    /// button; each renders only when the stream has an axis to move along —
    /// a standalone movie has neither episodes nor channels, and shows nothing.
    ///
    /// Call sites gate on `neighbours.axis != nil` rather than leaning on the
    /// `.none` branch below: an `EmptyView` returned from *inside* a concrete
    /// view is still a laid-out child, so a movie's transport row would keep
    /// the `HStack`'s spacing at both ends and sit wider than it does without
    /// this control at all.
    struct PlayerItemNavButton: View {
        /// Which neighbour this button plays.
        let step: PlayerMediaSwapper.Step
        /// Previous/next, resolved once per stream by the player host. Nothing
        /// here derives from the playback clock: the overlays hosting this
        /// re-render on a tick, which flickers open menus and drops in-flight
        /// taps, so enablement comes only from these precomputed values.
        let neighbours: PlayerItemNavigation.Neighbours
        let onStep: (PlayerMediaSwapper.Step) -> Void
        let onResetHideTimer: () -> Void

        var body: some View {
            switch neighbours.axis {
            case .episode:
                button(step == .next ? "forward.end.fill" : "backward.end.fill")
                    .accessibilityLabel(step == .next ? "Next Episode" : "Previous Episode")
            case .channel:
                // Deliberately not the seek glyphs' shape: these are the
                // remote's channel up/down, not `gobackward.15`/`goforward.15`.
                button(step == .next ? "chevron.up" : "chevron.down")
                    .accessibilityLabel(step == .next ? "Next Channel" : "Previous Channel")
            case .none:
                EmptyView()
            }
        }

        /// Whether this end is pressable, from the host-resolved neighbours
        /// alone. A series whose episodes the catalog hasn't fetched yet, and a
        /// list edge, both stay put and dim rather than disappearing, so the
        /// rest of the transport row doesn't slide out from under the viewer's
        /// finger.
        private var state: PlayerItemNavigation.ButtonState {
            neighbours.buttonState(for: step)
        }

        private func button(_ systemName: String) -> some View {
            Button {
                onStep(step)
                onResetHideTimer()
            } label: {
                circleGlyph(systemName, dimmed: state != .enabled)
            }
            .buttonStyle(.plain)
            .disabled(state != .enabled)
        }

        /// The metrics the skip-15 buttons use, so the row reads as one cluster.
        private func circleGlyph(_ systemName: String, dimmed: Bool) -> some View {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(dimmed ? .white.opacity(0.55) : .white)
                .frame(width: 60, height: 60)
                .contentShape(Circle())
                .glassEffectCompat(.regularInteractive, in: Circle())
        }
    }

#endif
