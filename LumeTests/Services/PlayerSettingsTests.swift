import Foundation
@testable import Lume
import Testing

struct PlayerSettingsTests {
    @Test func `engine kind all cases`() {
        #expect(PlayerEngineKind.allCases.count == 2)
        #expect(PlayerEngineKind.ksPlayer.rawValue == "ksPlayer")
        #expect(PlayerEngineKind.avPlayer.rawValue == "avPlayer")
    }

    @Test func `engine kind display names`() {
        #expect(PlayerEngineKind.ksPlayer.displayName == "KSPlayer")
        #expect(PlayerEngineKind.avPlayer.displayName == "AVPlayer")
    }

    @Test func `engine kind identifiable`() {
        #expect(PlayerEngineKind.ksPlayer.id == "ksPlayer")
        #expect(PlayerEngineKind.avPlayer.id == "avPlayer")
    }

    @Test func `engine kind subtitles not empty`() {
        for kind in PlayerEngineKind.allCases {
            #expect(!kind.subtitle.isEmpty)
        }
    }

    @Test func `engine kind subtitle content`() {
        #expect(PlayerEngineKind.ksPlayer.subtitle.contains("FFmpeg"))
        #expect(PlayerEngineKind.avPlayer.subtitle.contains("Native"))
    }

    @Test func `engine storage key`() {
        #expect(PlayerSettings.engineKey == "player.engine")
    }
}
