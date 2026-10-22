@testable import Lume
import SwiftUI
import Testing

struct PlayerKeyCommandTests {
    @Test func `bare keys drive the transport`() {
        #expect(PlayerKeyCommand(key: .space, modifiers: []) == .togglePlay)
        #expect(PlayerKeyCommand(key: .leftArrow, modifiers: []) == .skipBackward)
        #expect(PlayerKeyCommand(key: .rightArrow, modifiers: []) == .skipForward)
        #expect(PlayerKeyCommand(key: .escape, modifiers: []) == .close)
    }

    @Test func `bare up and down step the volume`() {
        #expect(PlayerKeyCommand(key: .upArrow, modifiers: []) == .volumeUp)
        #expect(PlayerKeyCommand(key: .downArrow, modifiers: []) == .volumeDown)
    }

    @Test func `command up and down step the channel`() {
        #expect(PlayerKeyCommand(key: .upArrow, modifiers: [.command]) == .nextChannel)
        #expect(PlayerKeyCommand(key: .downArrow, modifiers: [.command]) == .previousChannel)
    }

    @Test func `letters toggle mute and full screen`() {
        #expect(PlayerKeyCommand(key: "m", modifiers: []) == .toggleMute)
        #expect(PlayerKeyCommand(key: "f", modifiers: []) == .toggleFullScreen)
    }

    @Test func `caps lock and the arrow-key flags don't change the shortcut`() {
        #expect(PlayerKeyCommand(key: .upArrow, modifiers: [.numericPad, .function]) == .volumeUp)
        #expect(PlayerKeyCommand(key: .upArrow, modifiers: [.command, .numericPad, .function]) == .nextChannel)
        #expect(PlayerKeyCommand(key: "M", modifiers: [.capsLock]) == .toggleMute)
        #expect(PlayerKeyCommand(key: .space, modifiers: [.capsLock]) == .togglePlay)
    }

    @Test func `other chords are not player shortcuts`() {
        #expect(PlayerKeyCommand(key: .downArrow, modifiers: [.command, .option]) == nil)
        #expect(PlayerKeyCommand(key: .upArrow, modifiers: [.command, .shift]) == nil)
        #expect(PlayerKeyCommand(key: .upArrow, modifiers: [.option]) == nil)
        #expect(PlayerKeyCommand(key: .leftArrow, modifiers: [.command]) == nil)
        #expect(PlayerKeyCommand(key: .space, modifiers: [.control]) == nil)
        #expect(PlayerKeyCommand(key: "m", modifiers: [.shift]) == nil)
        #expect(PlayerKeyCommand(key: "f", modifiers: [.command]) == nil)
        #expect(PlayerKeyCommand(key: "x", modifiers: []) == nil)
    }

    @Test func `only steps repeat while a key is held`() {
        #expect(PlayerKeyCommand.skipForward.repeats)
        #expect(PlayerKeyCommand.volumeDown.repeats)
        #expect(PlayerKeyCommand.nextChannel.repeats)
        #expect(!PlayerKeyCommand.togglePlay.repeats)
        #expect(!PlayerKeyCommand.toggleMute.repeats)
        #expect(!PlayerKeyCommand.toggleFullScreen.repeats)
        #expect(!PlayerKeyCommand.close.repeats)
    }
}
