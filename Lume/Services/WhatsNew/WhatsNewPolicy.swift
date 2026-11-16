//
//  WhatsNewPolicy.swift
//  Lume
//
//  Decides whether an update raises the What's New sheet, and with which
//  release. Pure, so every case is a unit test.
//

import Foundation

nonisolated enum WhatsNewPolicy {
    /// The release to show after launching `current`, if any.
    ///
    /// - Parameter lastSeen: the version last acknowledged on this device. Nil
    ///   on an install that predates the feature: it gets the release it just
    ///   updated to, and nothing older.
    ///
    /// Only feature releases count, so a patch update shows nothing, and only
    /// the newest unseen release with highlights on this platform is shown; the
    /// ones skipped stay in the history.
    static func releaseToPresent(
        lastSeen: AppVersion?,
        current: AppVersion,
        releases: [WhatsNewRelease],
        platform: WhatsNewPlatform
    ) -> WhatsNewRelease? {
        releases
            .filter { release in
                let feature = release.version.feature
                guard feature <= current.feature, !release.highlights(on: platform).isEmpty else { return false }
                if let lastSeen {
                    return feature > lastSeen.feature
                }
                return feature == current.feature
            }
            .max { $0.version < $1.version }
    }
}

/// The version last acknowledged on this device. Device-local: every device
/// shows its own update once.
nonisolated struct WhatsNewStore {
    static let lastSeenVersionKey = "whatsNew.lastSeenVersion"

    /// UserDefaults is thread-safe but not declared Sendable.
    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSeenVersion: AppVersion? {
        get { defaults.string(forKey: Self.lastSeenVersionKey).flatMap(AppVersion.init) }
        nonmutating set { defaults.set(newValue?.storageString, forKey: Self.lastSeenVersionKey) }
    }
}
