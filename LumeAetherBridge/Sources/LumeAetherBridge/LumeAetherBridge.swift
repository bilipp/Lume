// Internal, never public: an AetherEngine type in this module's interface would
// pull the AetherLib* C modules into Lume's compile, where they clash with
// KSPlayer's Libav* modules over the same C type names.
internal import AetherEngine

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
}
