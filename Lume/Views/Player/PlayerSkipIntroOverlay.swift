import SwiftUI

/// In-player "Skip Intro" / "Skip Recap" affordance, layered above the active
/// engine's own controls by each engine view (mirroring `PlayerNextUpOverlay`,
/// so it can see whether the controls are showing and keep focus sane on tvOS).
///
/// A focused button fades in whenever the playhead sits inside a known intro or
/// recap window (data from `IntroDBClient`) and seeks just past it on activation.
/// Outro / end-credits skipping is intentionally left to the existing Next
/// Episode button and auto-advance, so the two affordances never overlap.
///
/// Reads the high-frequency `PlaybackClock`, so it re-renders on each tick — a
/// deliberately small leaf (like the scrubber) that never lifts that dependency
/// up into the engine view. Only mounted by the engine view when segments exist.
struct PlayerSkipIntroOverlay: View {
    let segments: IntroSegments
    /// The shared playback clock. Read here (and only here) so ticking it
    /// invalidates just this overlay, not the engine view above it.
    let clock: PlaybackClock
    /// Whether the engine's own controls overlay is currently showing. The
    /// button hides while the controls are up, so the two don't fight for focus
    /// (tvOS) or overlap the scrubber (iOS/macOS).
    let controlsVisible: Bool
    /// Seeks the underlying player to an absolute time, in seconds.
    let onSeek: (TimeInterval) -> Void

    #if os(tvOS)
        @FocusState private var buttonFocused: Bool
        /// Set when the viewer presses Menu on the button, so it stays dismissed
        /// for the current segment rather than reappearing each tick. Cleared
        /// when the segments change (a new episode swaps in).
        @State private var dismissedSegment: ActiveSegment?
    #endif

    /// Segments shorter than this aren't worth a button — avoids flashing an
    /// affordance for a one-second stinger.
    private let minimumDuration: TimeInterval = 5

    private enum Kind: Equatable { case intro, recap }

    private struct ActiveSegment: Equatable {
        let kind: Kind
        let segment: IntroSegments.Segment
    }

    var body: some View {
        Group {
            if let active, showsButton(for: active) {
                skipButton(for: active)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(active != nil)
        .animation(.easeInOut(duration: 0.25), value: active)
        #if os(tvOS)
            .onChange(of: active) { _, value in
                // Pull focus onto the button the moment it appears so the viewer can
                // skip with a single Select.
                if value != nil { Task { @MainActor in buttonFocused = true } }
            }
            .onChange(of: segments) { _, _ in
                dismissedSegment = nil
            }
        #endif
    }

    // MARK: - Gating

    /// The segment the playhead currently sits inside, or `nil` when between or
    /// outside segments. A recap takes precedence over an intro when both windows
    /// would match (some shows tag a "previously on" recap ahead of the titles).
    private var active: ActiveSegment? {
        let now = clock.current
        guard now > 0 else { return nil }
        if let recap = segments.recap, contains(recap, now) {
            return ActiveSegment(kind: .recap, segment: recap)
        }
        if let intro = segments.intro, contains(intro, now) {
            return ActiveSegment(kind: .intro, segment: intro)
        }
        return nil
    }

    private func contains(_ segment: IntroSegments.Segment, _ time: TimeInterval) -> Bool {
        segment.duration >= minimumDuration && time >= segment.start && time < segment.end
    }

    private func showsButton(for active: ActiveSegment) -> Bool {
        #if os(tvOS)
            if dismissedSegment == active { return false }
        #endif
        // Hide while the controls own the screen — their scrubber covers the
        // same bottom-trailing space (iOS/macOS) and focus (tvOS).
        return !controlsVisible
    }

    private func label(for kind: Kind) -> LocalizedStringKey {
        kind == .recap ? "Skip Recap" : "Skip Intro"
    }

    private func skip(_ active: ActiveSegment) {
        onSeek(active.segment.end)
    }

    // MARK: - Button

    @ViewBuilder
    private func skipButton(for active: ActiveSegment) -> some View {
        #if os(tvOS)
            // Matches `PlayerNextUpOverlay`'s tvOS button verbatim (glass style,
            // 26pt leading glyph, trailing Spacer + fixed 460pt width) so the two
            // in-player affordances are visually identical.
            Button { skip(active) } label: {
                HStack(spacing: 18) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text(label(for: active.kind))
                        .font(.system(size: 24, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 26)
            }
            .buttonStyle(TVGlassButtonStyle())
            .focused($buttonFocused)
            .frame(width: 460)
            .padding(.trailing, 80)
            .padding(.bottom, 60)
            // Menu on the button dismisses it for this segment (focus falls back
            // to the player) rather than closing the player outright.
            .onExitCommand { dismissedSegment = active }
        #else
            Button { skip(active) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text(label(for: active.kind))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .contentShape(Capsule())
                .glassEffectCompat(.regularInteractive, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 40)
        #endif
    }
}
