import Foundation
@testable import Lume
import Testing

struct PlayerSettingsTests {
    @Test func `engine kind all cases`() {
        #expect(PlayerEngineKind.allCases.count == 3)
        #expect(PlayerEngineKind.vlcKit.rawValue == "vlcKit")
        #expect(PlayerEngineKind.ksPlayer.rawValue == "ksPlayer")
        #expect(PlayerEngineKind.avPlayer.rawValue == "avPlayer")
    }

    @Test func `engine kind display names`() {
        #expect(PlayerEngineKind.vlcKit.displayName == "VLCKit")
        #expect(PlayerEngineKind.ksPlayer.displayName == "KSPlayer")
        #expect(PlayerEngineKind.avPlayer.displayName == "AVPlayer")
    }

    @Test func `engine kind identifiable`() {
        #expect(PlayerEngineKind.vlcKit.id == "vlcKit")
        #expect(PlayerEngineKind.ksPlayer.id == "ksPlayer")
        #expect(PlayerEngineKind.avPlayer.id == "avPlayer")
    }

    @Test func `engine kind subtitles not empty`() {
        for kind in PlayerEngineKind.allCases {
            #expect(!String(localized: kind.subtitle).isEmpty)
        }
    }

    @Test func `engine kind subtitle content`() {
        let ksSubtitle = String(localized: PlayerEngineKind.ksPlayer.subtitle)
        let avSubtitle = String(localized: PlayerEngineKind.avPlayer.subtitle)
        #expect(!ksSubtitle.isEmpty)
        #expect(!avSubtitle.isEmpty)
    }

    @Test func `engine renders own controls`() {
        #expect(PlayerEngineKind.vlcKit.rendersOwnControls == true)
        #expect(PlayerEngineKind.ksPlayer.rendersOwnControls == true)
        #expect(PlayerEngineKind.avPlayer.rendersOwnControls == false)
    }

    @Test func `engine storage key`() {
        #expect(PlayerSettings.engineKey == "player.engine")
    }
}
