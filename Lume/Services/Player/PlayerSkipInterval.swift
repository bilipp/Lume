//
//  PlayerSkipInterval.swift
//  Lume
//
//  How far skip back / skip forward jump: the player overlays, the arrow keys,
//  Now Playing's skip commands and the Cast screen all read this one value.
//

import Foundation

nonisolated struct PlayerSkipInterval: Equatable {
    /// Each has a matching `gobackward.N` / `goforward.N` SF Symbol.
    static let options = [5, 10, 15, 30, 45, 60]

    /// What each platform skipped before the setting existed, so a viewer who
    /// never opens it keeps the old behaviour.
    static var platformDefault: Int {
        #if os(tvOS)
            10
        #else
            15
        #endif
    }

    let seconds: Int

    /// An unset key reads as 0 and falls back to the platform default, as does
    /// any value outside `options`.
    init(seconds raw: Int) {
        seconds = Self.options.contains(raw) ? raw : Self.platformDefault
    }

    static func stored(in defaults: UserDefaults = .standard) -> PlayerSkipInterval {
        PlayerSkipInterval(seconds: defaults.integer(forKey: PlayerSettings.Playback.skipIntervalKey))
    }

    var timeInterval: TimeInterval {
        TimeInterval(seconds)
    }

    var backwardSymbol: String {
        "gobackward.\(seconds)"
    }

    var forwardSymbol: String {
        "goforward.\(seconds)"
    }

    /// "10 sec", "1 min" in the viewer's language, without a catalog entry.
    var displayName: String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}
