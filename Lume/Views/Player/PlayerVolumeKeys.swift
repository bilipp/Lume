//
//  PlayerVolumeKeys.swift
//  Lume
//
//  The macOS player's volume shortcuts: Cmd+Up / Cmd+Down step the level,
//  Cmd+Option+Down toggles mute. Bare Up/Down stay live-TV channel zapping.
//

import SwiftUI

nonisolated extension EventModifiers {
    /// The modifiers that make an arrow press a shortcut. Caps Lock and the
    /// numeric-pad / function flags AppKit stamps on every arrow key don't count.
    static let chordKeys: EventModifiers = [.command, .option, .control, .shift]

    /// No chord modifier, so a bare arrow is a channel step rather than a
    /// shortcut (Cmd+Up/Down is the player volume).
    var isBare: Bool {
        isDisjoint(with: .chordKeys)
    }
}

/// What a modified arrow press asks of the player volume, if anything.
nonisolated enum PlayerVolumeKeyCommand: Equatable {
    case stepUp
    case stepDown
    case toggleMute

    init?(key: KeyEquivalent, modifiers: EventModifiers) {
        let chord = modifiers.intersection(.chordKeys)
        switch chord {
        case [.command] where key == .upArrow: self = .stepUp
        case [.command] where key == .downArrow: self = .stepDown
        case [.command, .option] where key == .downArrow: self = .toggleMute
        default: return nil
        }
    }
}
