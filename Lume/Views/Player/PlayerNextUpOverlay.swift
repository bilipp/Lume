import SwiftUI

/// The end-of-episode "Next Up" affordances, layered above the active engine's
/// own controls by each engine view (so it can see whether the controls are
/// showing and keep focus sane on tvOS).
///
/// Two independent behaviours, each gated on its own setting:
///   • a focused **Next Episode** button, tvOS only, that fades in when the
///     episode reaches its outro — IntroDB's decoded credits window when one was
///     fetched and is plausible for this encode, otherwise 90% of the duration.
///     The armed time is clamped so it can only ever be *later* than that 90%
///     line, never earlier, so pressing the button always leaves the episode
///     past the "watched" threshold. Every other platform puts an
///     always-available Next Episode button in the transport row instead
///     (`PlayerItemNavButton`), and showing both would be two competing controls
///     over the same video — and
///   • **auto-advance**, which swaps to the next episode as the current one
///     reaches its end, on every platform. Auto-advance is deliberately not
///     outro-aware: it still fires only at the very end of the stream.
///
/// Both read the high-frequency `PlaybackClock`, so this view re-renders on each
/// tick — it is deliberately a small leaf (like the scrubber) and never lifts
/// that dependency up into the engine view. It is only mounted by the engine
/// view when a next episode actually exists, so `nextMedia` is non-optional.
struct PlayerNextUpOverlay: View {
    let nextMedia: PlayableMedia
    /// The shared playback clock. Read here (and only here) so ticking it
    /// invalidates just this overlay, not the engine view above it.
    let clock: PlaybackClock
    /// Whether the engine's own controls overlay is currently showing. The tvOS
    /// button hides while the controls are up, so the two don't fight for focus.
    let controlsVisible: Bool
    /// The IntroDB outro window for this episode when known; nil keeps the
    /// legacy 90% behaviour.
    let outro: IntroSegments.Segment?
    let onPlayNext: (PlayableMedia) -> Void

    @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
    private var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
    @AppStorage(PlayerSettings.Playback.showNextEpisodeButtonKey)
    private var showNextButton = PlayerSettings.Playback.showNextEpisodeButtonDefault

    /// Latches once auto-advance fires so a burst of end-of-stream ticks can't
    /// trigger it repeatedly. Reset when the media changes (a new episode swaps
    /// in, possibly reusing this view's identity).
    @State private var didAutoAdvance = false

    /// The next-up affordances are a Premium feature. Free users never see the
    /// button and never auto-advance, regardless of the stored toggle values.
    @State private var premium = PremiumManager.shared

    #if os(tvOS)
        @FocusState private var buttonFocused: Bool
        /// Set when the viewer presses Menu on the button, so it stays dismissed
        /// for the rest of this episode rather than reappearing each tick. Reset
        /// when the media changes.
        @State private var dismissed = false
    #endif

    var body: some View {
        Group {
            if showsButton {
                nextButton
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(showsButton)
        .animation(.easeInOut(duration: 0.25), value: showsButton)
        .onChange(of: shouldAutoAdvance) { _, advance in
            guard advance, !didAutoAdvance else { return }
            didAutoAdvance = true
            onPlayNext(nextMedia)
        }
        .onChange(of: nextMedia.id) { _, _ in
            didAutoAdvance = false
            #if os(tvOS)
                dismissed = false
            #endif
        }
        #if os(tvOS)
        .onChange(of: showsButton) { _, shows in
            // Pull focus onto the button the moment it appears so the viewer can
            // play the next episode with a single Select.
            if shows { Task { @MainActor in buttonFocused = true } }
        }
        #endif
    }

    // MARK: - Gating

    private var fraction: Double {
        guard clock.duration > 0 else { return 0 }
        return min(max(clock.current / clock.duration, 0), 1)
    }

    /// True once playback has reached the arm point `OutroTrigger` computes.
    /// It returns nil for a live or unknown-duration stream, which never arms.
    private var isArmed: Bool {
        guard let armTime = OutroTrigger.armTime(outro: outro, duration: clock.duration) else {
            return false
        }
        return clock.current >= armTime
    }

    private var showsButton: Bool {
        #if os(tvOS)
            guard premium.isPremium, showNextButton, !controlsVisible, clock.current > 0, isArmed else {
                return false
            }
            if dismissed { return false }
            return true
        #else
            // iOS / macOS / visionOS carry an always-available Next Episode
            // button in the transport row (`PlayerItemNavButton`), so this
            // outro-armed one would be a second, differently-gated control over
            // the same video. Auto-advance below is untouched.
            return false
        #endif
    }

    /// True as the episode reaches its end: within the last few seconds, or past
    /// 99.5% for content whose final ticks land short of the reported duration.
    private var shouldAutoAdvance: Bool {
        guard premium.isPremium, autoPlayNext, clock.duration > 1, clock.current > 0 else { return false }
        let remaining = clock.duration - clock.current
        return remaining <= 3 || fraction >= 0.995
    }

    // MARK: - Button

    @ViewBuilder
    private var nextButton: some View {
        #if os(tvOS)
            Button { onPlayNext(nextMedia) } label: {
                HStack(spacing: 18) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next Episode")
                            .font(.system(size: 24, weight: .semibold))
                        if let subtitle = nextMedia.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 19))
                                .opacity(0.7)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 26)
            }
            .buttonStyle(TVGlassButtonStyle())
            .focused($buttonFocused)
            .frame(width: 460)
            .padding(.trailing, 80)
            .padding(.bottom, 60)
            // Menu on the button dismisses it (focus falls back to the player)
            // rather than closing the player outright.
            .onExitCommand { dismissed = true }
        #else
            // Never reached: `showsButton` is false off tvOS.
            EmptyView()
        #endif
    }
}
