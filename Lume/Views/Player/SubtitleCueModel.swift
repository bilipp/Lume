import Combine

/// Holds the engine's active subtitle cue text, refreshed from the coordinator's
/// 10 Hz playback tick. Deliberately a separate `ObservableObject` from
/// `LumeEngineCoordinator`: were the cue text `@Published` on the coordinator,
/// every per-tick update would fire the coordinator's `objectWillChange` and
/// re-render every overlay that observes it — flickering an open audio/subtitle
/// `Menu` and cancelling in-flight taps. Only the subtitle-rendering leaf
/// observes this model, so a cue change invalidates that leaf alone. Mirrors why
/// KSPlayer keeps its `SubtitleModel` off the controls overlay's observed surface.
@MainActor
final class SubtitleCueModel: ObservableObject {
    @Published private(set) var text: String?

    /// Assigns only on an actual change, so an unchanged cue repeated across
    /// ticks doesn't invalidate the leaf ten times a second.
    func update(_ newText: String?) {
        if text != newText {
            text = newText
        }
    }
}
