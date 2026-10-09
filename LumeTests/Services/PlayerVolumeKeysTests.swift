@testable import Lume
import SwiftUI
import Testing

struct PlayerVolumeKeysTests {
    @Test func `bare arrows ignore caps lock and the arrow-key flags`() {
        #expect(EventModifiers([]).isBare)
        #expect(EventModifiers([.capsLock]).isBare)
        #expect(EventModifiers([.numericPad, .function]).isBare)
    }

    @Test func `chorded arrows are not channel steps`() {
        #expect(!EventModifiers([.command]).isBare)
        #expect(!EventModifiers([.option]).isBare)
        #expect(!EventModifiers([.control]).isBare)
        #expect(!EventModifiers([.shift]).isBare)
        #expect(!EventModifiers([.command, .option, .numericPad, .function]).isBare)
    }

    @Test func `command arrows step the volume`() {
        #expect(PlayerVolumeKeyCommand(key: .upArrow, modifiers: [.command]) == .stepUp)
        #expect(PlayerVolumeKeyCommand(key: .downArrow, modifiers: [.command]) == .stepDown)
        #expect(PlayerVolumeKeyCommand(key: .upArrow, modifiers: [.command, .numericPad, .function]) == .stepUp)
    }

    @Test func `command option down toggles mute`() {
        #expect(PlayerVolumeKeyCommand(key: .downArrow, modifiers: [.command, .option]) == .toggleMute)
        #expect(PlayerVolumeKeyCommand(key: .downArrow, modifiers: [.command, .option, .capsLock]) == .toggleMute)
    }

    @Test func `other presses are not volume shortcuts`() {
        #expect(PlayerVolumeKeyCommand(key: .upArrow, modifiers: []) == nil)
        #expect(PlayerVolumeKeyCommand(key: .downArrow, modifiers: []) == nil)
        #expect(PlayerVolumeKeyCommand(key: .upArrow, modifiers: [.command, .option]) == nil)
        #expect(PlayerVolumeKeyCommand(key: .upArrow, modifiers: [.command, .shift]) == nil)
        #expect(PlayerVolumeKeyCommand(key: .downArrow, modifiers: [.option]) == nil)
        #expect(PlayerVolumeKeyCommand(key: .leftArrow, modifiers: [.command]) == nil)
    }
}
