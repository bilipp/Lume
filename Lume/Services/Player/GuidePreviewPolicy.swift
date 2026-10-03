//
//  GuidePreviewPolicy.swift
//  Lume
//
//  The decisions behind the tvOS Guide's live channel preview, kept as pure,
//  cross-platform logic — no view state, no player — because the preview
//  itself is tvOS-only and the test target only runs on iOS simulators.
//

import Foundation

/// How the tvOS Guide's now-playing hero appears above the timeline.
/// `regular` and `small` play the muted preview (Lume Pro); without Pro, or
/// with the system's video autoplay off, they keep their size and show the
/// channel's logo instead.
nonisolated enum GuidePreviewMode: String, CaseIterable {
    case regular
    /// A shorter hero, so the guide shows two more rows.
    case small
    /// The regular hero with the logo in place of the video.
    case infoOnly
    /// No hero: the guide takes the full height.
    case off

    var displayName: String {
        switch self {
        case .regular: String(localized: "Regular")
        case .small: String(localized: "Small")
        case .infoOnly: String(localized: "Info Only")
        case .off: String(localized: "Off")
        }
    }

    /// Whether the hero may play the channel's video at all.
    var playsVideo: Bool {
        self == .regular || self == .small
    }

    var showsHero: Bool {
        self != .off
    }

    /// An unknown or missing stored value reads as the default.
    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .regular
    }
}

nonisolated enum GuidePreviewPolicy {
    /// How long focus has to rest on a channel before its preview starts. Also
    /// gates the Stalker `create_link` resolve, so browsing never spends one.
    static let settleDuration: Duration = .seconds(1)

    /// The pause before the preview opens a fresh stream after full screen
    /// closes, so the provider has released the previous connection.
    static let restartDelay: Duration = .milliseconds(1500)

    /// What the preview does when the Guide's focus changes.
    enum Step: Equatable {
        /// Keep whatever is (or isn't) playing.
        case keep
        /// Play this channel right away.
        case start(String)
        /// Play this channel once focus has rested on it for `settleDuration`.
        case settle(String)
    }

    /// Focus off the channels — on the rail, the tab bar or a sheet — keeps
    /// the last channel playing. Before anything has played, the Guide opens
    /// on its first channel straight away rather than showing an empty band.
    static func step(focused: String?, current: String?, first: String?) -> Step {
        guard let focused else {
            guard current == nil, let first else { return .keep }
            return .start(first)
        }
        return focused == current ? .keep : .settle(focused)
    }

    static func shouldPreview(suspended: Bool, syncing: Bool, failed: Bool) -> Bool {
        !suspended && !syncing && !failed
    }

    /// The programme airing at `date`, whichever cell the viewer has focused.
    static func currentProgramme(in cells: [EPGProgramCell], at date: Date) -> EPGProgramCell? {
        cells.first { $0.isLive(at: date) }
    }

    /// The earliest programme starting strictly after `date`. Passing "now"
    /// gives what airs after the current programme, or after a gap when
    /// nothing is on; an overlapping programme counts once it starts later.
    static func nextProgramme(in cells: [EPGProgramCell], after date: Date) -> EPGProgramCell? {
        cells.lazy
            .filter { !$0.isGap && $0.start > date }
            .min { $0.start < $1.start }
    }

    /// Whole minutes until `cell` ends, rounded up so a programme reads
    /// "1 min left" until its last second; never negative once it has ended.
    static func minutesLeft(of cell: EPGProgramCell, at date: Date) -> Int {
        let seconds = cell.end.timeIntervalSince(date)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 60).rounded(.up))
    }

    /// Whether the preview's running player can be adopted by full screen.
    /// VLCKit and LumeEngine can't hand their session over, and AirPlay routes
    /// full screen through a fresh AVPlayer, so those stop the preview first.
    static func supportsHandoff(engine: PlayerEngineKind, airPlayActive: Bool) -> Bool {
        guard !airPlayActive else { return false }
        switch engine {
        case .ksPlayer, .avPlayer: return true
        case .vlcKit, .lumeEngine: return false
        }
    }
}
