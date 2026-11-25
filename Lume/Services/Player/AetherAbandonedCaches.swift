//
//  AetherAbandonedCaches.swift
//  Lume
//
//  The launch-time cleanup of what a killed process left of AetherEngine's
//  temporary files. The app and its tests reach the bridge through here: the
//  test bundle does not link `LumeAetherBridge` itself.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    enum AetherAbandonedCaches {
        /// See `LumeAetherBridge.removeAbandonedCaches(in:)`.
        @discardableResult
        static func remove(in directory: URL = FileManager.default.temporaryDirectory) async -> Int {
            await LumeAetherBridge.removeAbandonedCaches(in: directory)
        }
    }

#endif
