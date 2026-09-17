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
                    onPlayNext: onSelectMedia
                )
            }

            if let segments {
                PlayerSkipIntroOverlay(
                    segments: segments,
                    clock: clock,
                    controlsVisible: controlsVisible,
                    onSeek: onSeek
                )
            }
        }
    }
}
