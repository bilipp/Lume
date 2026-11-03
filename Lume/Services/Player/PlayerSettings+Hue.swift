import Foundation

// MARK: - Philips Hue

extension PlayerSettings {
    /// Philips Hue light sync. Device-local, never synced, and one setting for
    /// every profile. The bridge's host and id and the area id sit outside
    /// `player.` so the diagnostic report never lists them; its keys live in
    /// `HueCredentialStore`.
    nonisolated enum Hue {
        static let enabledKey = "player.hue.enabled"
        static let intensityKey = "player.hue.intensity"
        /// The `entertainment_configuration` id the lamps stream to.
        static let entertainmentAreaKey = "hue.entertainmentArea"
        static let lightSensitivityNoticeShownKey = "player.hue.lightSensitivityNoticeShown"
        /// JSON `HueLightSnapshot`, written before streaming starts and removed
        /// once the lamps are restored, so a crash mid-stream restores on the
        /// next launch.
        static let restoreSnapshotKey = "hue.restoreSnapshot"
        static let bridgeHostKey = "hue.bridge.host"
        static let bridgeIDKey = "hue.bridge.id"

        static let enabledDefault = false
        static let intensityDefault = HueIntensity.moderate

        static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
            defaults.bool(enabledKey, default: enabledDefault)
        }

        /// The stored level; never `.off`, which is `isEnabled == false`.
        static func intensity(in defaults: UserDefaults = .standard) -> HueIntensity {
            guard let raw = defaults.string(forKey: intensityKey),
                  let intensity = HueIntensity(rawValue: raw), intensity != .off
            else { return intensityDefault }
            return intensity
        }

        /// What the player menu checks: `.off` while sync is disabled.
        static func selection(in defaults: UserDefaults = .standard) -> HueIntensity {
            isEnabled(in: defaults) ? intensity(in: defaults) : .off
        }

        /// `.off` disables sync and keeps the level for the next time it's on.
        static func setSelection(_ selection: HueIntensity, in defaults: UserDefaults = .standard) {
            defaults.set(selection != .off, forKey: enabledKey)
            if selection != .off {
                defaults.set(selection.rawValue, forKey: intensityKey)
            }
        }

        static func entertainmentAreaID(in defaults: UserDefaults = .standard) -> String? {
            defaults.string(forKey: entertainmentAreaKey).flatMap { $0.isEmpty ? nil : $0 }
        }

        static func setEntertainmentAreaID(_ id: String?, in defaults: UserDefaults = .standard) {
            if let id, !id.isEmpty {
                defaults.set(id, forKey: entertainmentAreaKey)
            } else {
                defaults.removeObject(forKey: entertainmentAreaKey)
            }
        }

        static func lightSensitivityNoticeShown(in defaults: UserDefaults = .standard) -> Bool {
            defaults.bool(forKey: lightSensitivityNoticeShownKey)
        }

        static func markLightSensitivityNoticeShown(in defaults: UserDefaults = .standard) {
            defaults.set(true, forKey: lightSensitivityNoticeShownKey)
        }

        /// Nil when nothing is pending or the stored value no longer decodes.
        static func restoreSnapshot(in defaults: UserDefaults = .standard) -> HueLightSnapshot? {
            guard let data = defaults.data(forKey: restoreSnapshotKey) else { return nil }
            return try? JSONDecoder().decode(HueLightSnapshot.self, from: data)
        }

        static func saveRestoreSnapshot(_ snapshot: HueLightSnapshot, in defaults: UserDefaults = .standard) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: restoreSnapshotKey)
        }

        static func clearRestoreSnapshot(in defaults: UserDefaults = .standard) {
            defaults.removeObject(forKey: restoreSnapshotKey)
        }
    }
}
