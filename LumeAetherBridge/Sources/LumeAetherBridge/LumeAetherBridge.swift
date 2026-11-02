// Internal, never public: an AetherEngine type in this module's interface would
// pull the AetherLib* C modules into Lume's compile, where they clash with
// KSPlayer's Libav* modules over the same C type names.
internal import AetherEngine

public enum LumeAetherBridge {
    public static var engineVersion: String {
        AetherEngine.version
    }
}
