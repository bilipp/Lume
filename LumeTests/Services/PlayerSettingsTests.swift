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
        // Every engine now draws its own in-player controls overlay — AVPlayer
        // gained custom controls in 49c44dd — so the host suppresses its own
        // close button for each (see FullScreenPlayerView).
        #expect(PlayerEngineKind.vlcKit.rendersOwnControls)
        #expect(PlayerEngineKind.ksPlayer.rendersOwnControls)
        #expect(PlayerEngineKind.avPlayer.rendersOwnControls)
    }

    @Test func `engine storage key`() {
        #expect(PlayerSettings.engineKey == "player.engine")
    }

    @Test func `engine priority storage key`() {
        #expect(PlayerSettings.enginePriorityKey == "player.enginePriority")
    }
}

struct PlayerEnginePriorityTests {
    @Test func `encode and decode round-trips`() {
        let list: [PlayerEngineKind] = [.avPlayer, .vlcKit, .ksPlayer]
        let encoded = PlayerEnginePriority.encode(list)
        #expect(encoded == "avPlayer,vlcKit,ksPlayer")
        #expect(PlayerEnginePriority.decode(encoded) == list)
    }

    @Test func `decode drops unknown tokens`() {
        #expect(PlayerEnginePriority.decode("vlcKit,bogus,avPlayer") == [.vlcKit, .avPlayer])
        #expect(PlayerEnginePriority.decode("") == [])
    }

    @Test func `normalized keeps order, dedupes, and appends missing engines`() {
        // Duplicates collapse to the first occurrence...
        let deduped = PlayerEnginePriority.normalized([.avPlayer, .avPlayer, .vlcKit])
        // ...and every remaining engine is appended in declaration order.
        #expect(deduped == [.avPlayer, .vlcKit, .ksPlayer])
        // A complete list is returned unchanged.
        #expect(PlayerEnginePriority.normalized([.ksPlayer, .avPlayer, .vlcKit]) == [.ksPlayer, .avPlayer, .vlcKit])
        // Every engine always appears exactly once.
        #expect(Set(PlayerEnginePriority.normalized([])) == Set(PlayerEngineKind.allCases))
        #expect(PlayerEnginePriority.normalized([]).count == PlayerEngineKind.allCases.count)
    }

    @Test func `resolve uses the stored priority when present`() {
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "ksPlayer,avPlayer,vlcKit",
            legacyEngineRaw: PlayerEngineKind.vlcKit.rawValue
        )
        #expect(resolved == [.ksPlayer, .avPlayer, .vlcKit])
    }

    @Test func `resolve completes a partial stored priority`() {
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "avPlayer",
            legacyEngineRaw: PlayerEngineKind.vlcKit.rawValue
        )
        #expect(resolved.first == .avPlayer)
        #expect(Set(resolved) == Set(PlayerEngineKind.allCases))
        #expect(resolved.count == PlayerEngineKind.allCases.count)
    }

    @Test func `resolve migrates the legacy engine as primary when no priority stored`() {
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "",
            legacyEngineRaw: PlayerEngineKind.avPlayer.rawValue
        )
        #expect(resolved.first == .avPlayer)
        #expect(Set(resolved) == Set(PlayerEngineKind.allCases))
    }

    @Test func `resolve falls back to the default engine for an unknown legacy value`() {
        let resolved = PlayerEnginePriority.resolve(priorityRaw: "", legacyEngineRaw: "bogus")
        #expect(resolved.first == .defaultValue)
        #expect(resolved.count == PlayerEngineKind.allCases.count)
    }

    @Test func `default priority is KSPlayer then VLCKit then AVPlayer`() {
        #expect(PlayerEngineKind.defaultValue == .ksPlayer)
        // A fresh install (no stored priority, engine key defaults to the default
        // engine) resolves to the documented default order.
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "",
            legacyEngineRaw: PlayerEngineKind.defaultValue.rawValue
        )
        #expect(resolved == [.ksPlayer, .vlcKit, .avPlayer])
    }
}
