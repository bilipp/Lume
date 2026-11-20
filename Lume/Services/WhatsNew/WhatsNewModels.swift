//
//  WhatsNewModels.swift
//  Lume
//
//  The value types behind the What's New sheet and the release history: a
//  comparable app version, the platforms an entry applies to, and a release
//  with its highlights and notes.
//

import Foundation

/// A marketing version (`CFBundleShortVersionString`), comparable by part.
nonisolated struct AppVersion: Comparable, Hashable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "3", "3.2" or "3.2.1". Anything else, the "—" placeholder of a
    /// missing Info.plist value included, is nil.
    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1 ... 3).contains(parts.count), !parts.contains(nil) else { return nil }
        let numbers = parts.compactMap(\.self)
        guard numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.init(numbers[0], numbers.count > 1 ? numbers[1] : 0, numbers.count > 2 ? numbers[2] : 0)
    }

    /// The feature release this version belongs to: 3.2.1 is part of 3.2. Patch
    /// updates never count as something new.
    var feature: AppVersion {
        AppVersion(major, minor)
    }

    /// "3.2", or "3.2.1" for a patch release.
    var displayString: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    var storageString: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A platform an entry can be limited to. iPadOS counts as iOS.
nonisolated enum WhatsNewPlatform: CaseIterable {
    case iOS, macOS, tvOS, visionOS

    static var current: WhatsNewPlatform {
        #if os(tvOS)
            .tvOS
        #elseif os(macOS)
            .macOS
        #elseif os(visionOS)
            .visionOS
        #else
            .iOS
        #endif
    }
}

/// One thing a release brought: a highlight in the sheet, or a line in the
/// history.
nonisolated struct WhatsNewItem: Identifiable {
    /// Stable across releases of the app, e.g. "3.3.stalker-guide".
    let id: String
    /// An SF Symbol name.
    let symbol: String
    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    /// Where the feature exists. An item is never shown anywhere else.
    var platforms: Set<WhatsNewPlatform> = Set(WhatsNewPlatform.allCases)
    /// Marks a Lume Pro feature with the crown.
    var isPro = false
}

/// What one feature release (x.y) brought.
nonisolated struct WhatsNewRelease: Identifiable {
    let version: AppVersion
    /// Shown in the sheet after the update, and at the top of the history
    /// entry. A release without any raises no sheet.
    let highlights: [WhatsNewItem]
    /// Smaller changes, listed in the history only.
    var notes: [LocalizedStringResource] = []

    var id: AppVersion {
        version
    }

    func highlights(on platform: WhatsNewPlatform) -> [WhatsNewItem] {
        highlights.filter { $0.platforms.contains(platform) }
    }

    /// Whether the history has anything to list for this release.
    func hasContent(on platform: WhatsNewPlatform) -> Bool {
        !notes.isEmpty || !highlights(on: platform).isEmpty
    }
}
