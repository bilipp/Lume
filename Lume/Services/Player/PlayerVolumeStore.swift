import Foundation
import Observation

/// The macOS player's app-level volume for one player session. `level`
/// persists device-locally under `PlayerSettings.volumeKey`, written only by
/// `commit()` (slider release, key step) — never per drag tick. `isMuted` is
/// session-only, so every new player opens unmuted at the stored level.
@MainActor @Observable
final class PlayerVolumeStore {
    private(set) var level: Float
    private(set) var isMuted = false
    /// Set by the engine while AirPlay owns the volume; the control hides and
    /// the keys stand down.
    var isRoutedExternally = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastAudibleLevel: Float?

    var effective: Float {
        PlayerVolumeMath.effective(level: level, muted: isMuted)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = PlayerSettings.volume(in: defaults)
        level = stored
        lastAudibleLevel = stored > 0 ? stored : nil
    }

    /// A zero level reads as muted too, so toggling it brings the sound back
    /// rather than muting an already silent player. That restored level is a
    /// level change, so it persists; the next player must not open silent.
    func toggleMute() {
        if isMuted || level <= 0 {
            isMuted = false
            if level <= 0 {
                level = lastAudibleLevel ?? 0.5
                commit()
            }
        } else {
            isMuted = true
        }
    }

    func setLevel(_ newLevel: Float) {
        level = PlayerVolumeMath.clamped(newLevel)
        if level > 0 {
            lastAudibleLevel = level
            isMuted = false
        }
    }

    func step(up raise: Bool) {
        let delta = raise ? PlayerVolumeMath.keyStep : -PlayerVolumeMath.keyStep
        setLevel(PlayerVolumeMath.step(level, by: delta))
        commit()
    }

    func commit() {
        defaults.set(level, forKey: PlayerSettings.volumeKey)
    }
}
