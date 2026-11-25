// Internal, never public: an AetherEngine type in this module's interface would
// pull the AetherLib* C modules into Lume's compile, where they clash with
// KSPlayer's Libav* modules over the same C type names.
internal import AetherEngine
import Foundation

public enum LumeAetherBridge {
    public static var engineVersion: String {
        AetherEngine.version
    }

    /// Names a value the engine must never log, such as a provider password
    /// that rides a stream URL as a bare path segment the engine can't
    /// recognise as a credential. Its exact and percent-encoded forms are
    /// replaced in every engine line. Values shorter than four bytes are
    /// refused (false). Registrations are counted; pair each with
    /// `unregisterLogSecret`.
    @discardableResult
    public static func registerLogSecret(_ value: String) -> Bool {
        EngineLog.registerSecret(value)
    }

    public static func unregisterLogSecret(_ value: String) {
        EngineLog.unregisterSecret(value)
    }

    /// Set by the first `LumeAetherSession`, after which the engine's
    /// temporary files may belong to a running session.
    static var hasCreatedSession = false

    /// Deletes what earlier processes of this app left in the temporary
    /// directory: the engine removes a session's segment cache when the
    /// session stops, so a process killed while one was open (the system
    /// ending a suspended app mid-film) leaves up to its whole budget
    /// behind. The engine sweeps such leftovers itself only when the next
    /// native session starts, and only those older than an hour.
    ///
    /// Call it once at launch. It does nothing once a session exists in this
    /// process. The leftovers are renamed aside before it returns, so a
    /// session created right after cannot lose its files, and deleted off
    /// the main actor; the result is how many entries were removed.
    ///
    /// The names are the engine's own and not part of its API (7.75.0:
    /// `aether-segments/`, `aether-software-packets-*`, `aether-fel-history/`,
    /// `aether-outgoing-hold-*`, `aether-sidecar-*`); check them on an engine
    /// update.
    @discardableResult
    public static func removeAbandonedCaches(
        in directory: URL = FileManager.default.temporaryDirectory
    ) async -> Int {
        guard !hasCreatedSession else { return 0 }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        // A sweep that was itself cut short left its holding directory.
        var doomed = names.filter { $0.hasPrefix(holdingPrefix) }.map { directory.appendingPathComponent($0) }
        var moved = 0
        let leftovers = names.filter { $0.hasPrefix(enginePrefix) }
        if !leftovers.isEmpty {
            let holding = directory.appendingPathComponent(holdingPrefix + UUID().uuidString, isDirectory: true)
            if (try? manager.createDirectory(at: holding, withIntermediateDirectories: false)) != nil {
                for name in leftovers {
                    let source = directory.appendingPathComponent(name)
                    if (try? manager.moveItem(at: source, to: holding.appendingPathComponent(name))) != nil {
                        moved += 1
                    }
                }
                doomed.append(holding)
            }
        }
        guard !doomed.isEmpty else { return 0 }
        let targets = doomed
        await Task.detached(priority: .utility) {
            for url in targets {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
        return moved
    }

    private static let enginePrefix = "aether-"
    private static let holdingPrefix = "lume-aether-abandoned-"
}
