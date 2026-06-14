import Foundation

/// The id of the currently active profile, persisted in `UserDefaults`.
///
/// A small scalar flag (not structured data), so `UserDefaults` is appropriate —
/// and it must be reachable from the sync engine's background actor *without* a
/// SwiftData fetch, which is why it lives here rather than on a model. Written by
/// `ProfileManager`, read by `CloudSyncEngine` to scope content reconciliation.
nonisolated enum ActiveProfileStore {
    static let key = "profiles.activeProfileID.v1"

    static var current: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
