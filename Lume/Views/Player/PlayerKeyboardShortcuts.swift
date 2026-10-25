//
//  PlayerKeyboardShortcuts.swift
//  Lume
//
//  The full-screen player's hardware-keyboard shortcuts on macOS and iPadOS:
//  Space plays/pauses, Left/Right skip 15 s, Cmd+Up/Down step the live channel
//  and Esc closes. macOS adds its app-level volume on bare Up/Down and M, and F
//  for full screen.
//

import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

nonisolated extension EventModifiers {
    /// The modifiers that make a key press a different shortcut. Caps Lock and
    /// the numeric-pad / function flags AppKit stamps on every arrow key don't
    /// count.
    static let chordKeys: EventModifiers = [.command, .option, .control, .shift]
}

/// What a key press in the full-screen player asks for, if anything. The same
/// on every platform; the handler drops what a platform can't do, such as the
/// volume on iPadOS, which keeps the system volume.
nonisolated enum PlayerKeyCommand: Equatable {
    case togglePlay
    case skipBackward
    case skipForward
    case volumeUp
    case volumeDown
    case toggleMute
    case nextChannel
    case previousChannel
    case toggleFullScreen
    case close

    private static let bare: [KeyEquivalent: PlayerKeyCommand] = [
        .space: .togglePlay,
        .leftArrow: .skipBackward,
        .rightArrow: .skipForward,
        .upArrow: .volumeUp,
        .downArrow: .volumeDown,
        "m": .toggleMute,
        "f": .toggleFullScreen,
        .escape: .close
    ]

    private static let command: [KeyEquivalent: PlayerKeyCommand] = [
        .upArrow: .nextChannel,
        .downArrow: .previousChannel
    ]

    init?(key: KeyEquivalent, modifiers: EventModifiers) {
        // Caps Lock reports letters in upper case.
        let key = key.character.lowercased().first.map { KeyEquivalent($0) } ?? key
        let bindings: [KeyEquivalent: PlayerKeyCommand] = switch modifiers.intersection(.chordKeys) {
        case []: Self.bare
        case [.command]: Self.command
        default: [:]
        }
        guard let command = bindings[key] else { return nil }
        self = command
    }

    /// Whether holding the key keeps acting at the key-repeat rate. A held
    /// toggle would flip back and forth.
    var repeats: Bool {
        switch self {
        case .skipBackward, .skipForward, .volumeUp, .volumeDown, .nextChannel, .previousChannel: true
        case .togglePlay, .toggleMute, .toggleFullScreen, .close: false
        }
    }
}

/// What an engine view hands the shortcuts to drive.
struct PlayerKeyActions {
    var togglePlay: () -> Void
    var skip: (TimeInterval) -> Void
    var close: () -> Void
    /// Keeps visible controls up after a transport key, as a click would.
    var resetHideTimer: () -> Void
    /// Brings the controls up for a key with nothing else on screen to show
    /// for it: the volume.
    var showControls: () -> Void
    var neighbours: PlayerItemNavigation.Neighbours
    var swapper: PlayerMediaSwapper
    var selectMedia: (PlayableMedia) -> Void
}

extension View {
    /// Applied once per engine view, outermost in its modifier chain. Does
    /// nothing on tvOS, where the Siri Remote has its own handling, or on
    /// visionOS.
    @ViewBuilder
    func playerKeyboardShortcuts(_ actions: PlayerKeyActions) -> some View {
        #if os(macOS) || os(iOS)
            modifier(PlayerKeyboardShortcuts(actions: actions))
        #else
            self
        #endif
    }
}

#if os(macOS) || os(iOS)
    private struct PlayerKeyboardShortcuts: ViewModifier {
        static let skipInterval: TimeInterval = 15

        let actions: PlayerKeyActions

        @FocusState private var isFocused: Bool
        #if os(macOS)
            @Environment(PlayerVolumeStore.self) private var playerVolume: PlayerVolumeStore?
        #endif

        func body(content: Content) -> some View {
            content
                // `onKeyPress` only hears presses on the focused view's chain,
                // and nothing in the player takes keyboard focus by itself:
                // buttons don't without Full Keyboard Access. Without this
                // every shortcut was silently dropped.
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    guard let command = PlayerKeyCommand(key: press.key, modifiers: press.modifiers) else {
                        return .ignored
                    }
                    guard press.phase == .down || command.repeats else { return .handled }
                    return perform(command)
                }
        }

        private func perform(_ command: PlayerKeyCommand) -> KeyPress.Result {
            switch command {
            case .togglePlay:
                actions.togglePlay()
            case .skipBackward:
                actions.skip(-Self.skipInterval)
            case .skipForward:
                actions.skip(Self.skipInterval)
            case .nextChannel, .previousChannel:
                return stepChannel(command == .nextChannel ? .next : .previous)
            case .volumeUp, .volumeDown, .toggleMute:
                return adjustVolume(command)
            case .toggleFullScreen:
                return toggleFullScreen()
            case .close:
                actions.close()
                return .handled
            }
            actions.resetHideTimer()
            return .handled
        }

        /// Live TV only: `.channel` is the axis a live stream (and not a
        /// catch-up recording) carries, so during a movie or an episode the
        /// press is left to the responder chain rather than silently stepping
        /// the series. Over live TV it is consumed whether or not the swapper's
        /// debounce let it through, so AppKit never moves focus out of the
        /// video.
        private func stepChannel(_ step: PlayerMediaSwapper.Step) -> KeyPress.Result {
            guard actions.neighbours.axis == .channel else { return .ignored }
            actions.swapper.step(step, in: actions.neighbours, select: actions.selectMedia)
            actions.resetHideTimer()
            return .handled
        }

        /// The app-level volume is macOS only, and stands down while AirPlay
        /// owns the volume. Without a store in the environment (previews) the
        /// keys are left alone.
        private func adjustVolume(_ command: PlayerKeyCommand) -> KeyPress.Result {
            #if os(macOS)
                guard let playerVolume, !playerVolume.isRoutedExternally else { return .ignored }
                switch command {
                case .volumeUp: playerVolume.step(up: true)
                case .volumeDown: playerVolume.step(up: false)
                default: playerVolume.toggleMute()
                }
                actions.showControls()
                return .handled
            #else
                return .ignored
            #endif
        }

        private func toggleFullScreen() -> KeyPress.Result {
            #if os(macOS)
                guard let window = NSApp.keyWindow else { return .ignored }
                window.toggleFullScreen(nil)
                return .handled
            #else
                return .ignored
            #endif
        }
    }
#endif
