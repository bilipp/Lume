import SwiftUI

/// The end-of-episode affordances every engine host layers above its own
/// controls, mounted as one view because they are one feature: a single IntroDB
/// lookup drives both the Skip Intro button (intro / recap windows) and the arm
/// time of the Next Episode button (outro window).
///
/// The engines differ only in how they seek and what they hand focus back to
/// afterwards, so that comes in as a closure.
struct PlayerEpisodeOverlays: View {
    /// Intro / recap / outro windows for the active episode (from IntroDB);
    /// `nil` when IntroDB knows nothing about it.
    let segments: IntroSegments?
    /// The episode queued after the current one; `nil` when there is nothing to
    /// play next.
    let nextUpMedia: PlayableMedia?
    /// The shared playback clock, threaded down as the `@Observable` object so
    /// only the leaves that read it re-render on a tick.
    let clock: PlaybackClock
    /// Whether the engine's own controls overlay is currently showing.
    let controlsVisible: Bool
    /// What the host and these overlays tell each other about the controls.
    let link: PlayerEpisodeOverlayLink
    /// Seeks the underlying player to an absolute time, in seconds.
    let onSeek: (TimeInterval) -> Void
    let onSelectMedia: (PlayableMedia) -> Void

    var body: some View {
        ZStack {
            if let nextUpMedia {
                PlayerNextUpOverlay(
                    nextMedia: nextUpMedia,
                    clock: clock,
                    controlsVisible: controlsVisible,
                    outro: segments?.outro,
                    link: link,
                    onPlayNext: onSelectMedia
                )
            }

            if let segments {
                PlayerSkipIntroOverlay(
                    segments: segments,
                    clock: clock,
                    controlsVisible: controlsVisible,
                    link: link,
                    onSeek: onSeek
                )
            }
        }
    }
}

/// What an engine host and its episode overlays tell each other about the
/// controls. Held in the host's `@State` and read only by the overlay leaves,
/// so neither change re-renders the host.
@Observable
final class PlayerEpisodeOverlayLink {
    enum FocusClaimant: Hashable { case skipIntro, nextEpisode }

    /// Height of the iOS / macOS / visionOS controls' bottom bar (title,
    /// secondary controls, timeline), reported through
    /// `PlayerControlsBarHeightKey`. Skip Intro sits above it while the
    /// controls show — on macOS they follow the pointer, so a button that hid
    /// with them could never be clicked. Keeps the last height measured, since
    /// the bar unmounts as the controls hide. Always 0 on tvOS.
    private(set) var controlsBarHeight: CGFloat = 0

    /// The tvOS episode buttons that want the Siri Remote's focus right now.
    /// Both hide while the controls are up, so they reappear in the same update
    /// that hides the controls — the update in which the host also hands focus
    /// to its full-screen tap-catcher. The catcher has to lose: once it holds
    /// focus there is nowhere to move to, every direction raises the controls
    /// again, and the button can never be reached.
    ///
    /// Not observed: the overlays write it from `onChange` during that update,
    /// and the host reads it from the `Task` it schedules there, which runs
    /// after the update. Nothing renders from it.
    @ObservationIgnored private var focusClaimants: Set<FocusClaimant> = []

    func reportControlsBarHeight(_ height: CGFloat) {
        guard height > 0, height != controlsBarHeight else { return }
        controlsBarHeight = height
    }

    func claimFocus(_ claimant: FocusClaimant, _ claiming: Bool) {
        if claiming {
            focusClaimants.insert(claimant)
        } else {
            focusClaimants.remove(claimant)
        }
    }

    /// The host's handoff once the controls hide: the tap-catcher gets focus
    /// so the remote can raise them again, unless an episode button is
    /// reappearing and taking it.
    @discardableResult
    func controlsDidHide(focusCatcher: @escaping () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            if focusClaimants.isEmpty { focusCatcher() }
        }
    }
}

/// The height of the iOS / macOS / visionOS controls' bottom bar, read by the
/// host into `PlayerEpisodeOverlayLink.controlsBarHeight`.
struct PlayerControlsBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports this view's height as the controls' bottom bar.
    func reportsPlayerControlsBarHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: PlayerControlsBarHeightKey.self, value: proxy.size.height)
            }
        }
    }
}
