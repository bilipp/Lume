import Foundation
@testable import Lume
import Testing

struct PlayerSettingsTests {
    @Test func `engine kind all cases`() {
        #expect(PlayerEngineKind.allCases.count == 4)
        #expect(PlayerEngineKind.lumeEngine.rawValue == "lumeEngine")
        #expect(PlayerEngineKind.vlcKit.rawValue == "vlcKit")
        #expect(PlayerEngineKind.ksPlayer.rawValue == "ksPlayer")
        #expect(PlayerEngineKind.avPlayer.rawValue == "avPlayer")
    }

    @Test func `engine kind display names`() {
        #expect(PlayerEngineKind.vlcKit.displayName == "VLCKit")
        #expect(PlayerEngineKind.ksPlayer.displayName == "KSPlayer")
        #expect(PlayerEngineKind.lumeEngine.displayName == "Lume Engine (Beta)")
        #expect(PlayerEngineKind.avPlayer.displayName == "AVPlayer")
    }

    @Test func `engine kind identifiable`() {
        #expect(PlayerEngineKind.vlcKit.id == "vlcKit")
        #expect(PlayerEngineKind.ksPlayer.id == "ksPlayer")
        #expect(PlayerEngineKind.lumeEngine.id == "lumeEngine")
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
        #expect(PlayerEngineKind.lumeEngine.rendersOwnControls)
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
        // ...and every remaining engine is appended in declaration order —
        // the beta LumeEngine always lands at the end.
        #expect(deduped == [.avPlayer, .vlcKit, .ksPlayer, .lumeEngine])
        // A complete list is returned unchanged.
        #expect(PlayerEnginePriority.normalized([.ksPlayer, .avPlayer, .vlcKit, .lumeEngine]) == [.ksPlayer, .avPlayer, .vlcKit, .lumeEngine])
        // Every engine always appears exactly once.
        #expect(Set(PlayerEnginePriority.normalized([])) == Set(PlayerEngineKind.allCases))
        #expect(PlayerEnginePriority.normalized([]).count == PlayerEngineKind.allCases.count)
    }

    @Test func `resolve uses the stored priority when present`() {
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "ksPlayer,avPlayer,vlcKit",
            legacyEngineRaw: PlayerEngineKind.vlcKit.rawValue
        )
        #expect(resolved == [.ksPlayer, .avPlayer, .vlcKit, .lumeEngine])
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

    @Test func `default priority is KSPlayer then VLCKit then AVPlayer, LumeEngine beta last`() {
        #expect(PlayerEngineKind.defaultValue == .ksPlayer)
        // A fresh install (no stored priority, engine key defaults to the default
        // engine) resolves to the documented default order, with the beta
        // LumeEngine appended last as an opt-in.
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "",
            legacyEngineRaw: PlayerEngineKind.defaultValue.rawValue
        )
        #expect(resolved == [.ksPlayer, .vlcKit, .avPlayer, .lumeEngine])
    }
}

// MARK: - Preferred track languages

struct PreferredLanguageStorageTests {
    /// Both lists are device-local `UserDefaults`, so every case runs against
    /// its own suite — `UserDefaults.standard` is shared with the rest of the
    /// suite and races itself.
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PreferredLanguageStorageTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        guard let defaults = UserDefaults(suiteName: name) else { return }
        try body(defaults)
    }

    @Test func `storage key`() {
        #expect(PlayerSettings.Language.preferredAudioLanguagesKey == "player.preferredAudioLanguages")
    }

    @Test func `the list ships empty`() {
        // The shipped default is "no preference at all": every engine then
        // leaves track selection exactly as the container asks for it.
        #expect(PlayerSettings.Language.preferredAudioLanguagesDefault == "")
    }

    @Test func `load yields an empty array for an untouched key`() {
        withSuite { defaults in
            let options = PlayerLanguageOptions.load(from: defaults)
            #expect(options.preferredAudioLanguages.isEmpty)
        }
    }

    @Test func `load reads the stored list in order`() {
        withSuite { defaults in
            defaults.set("de,en", forKey: PlayerSettings.Language.preferredAudioLanguagesKey)
            let options = PlayerLanguageOptions.load(from: defaults)
            #expect(options.preferredAudioLanguages == ["de", "en"])
        }
    }

    @Test func `an empty stored string still means no preference`() {
        withSuite { defaults in
            defaults.set("", forKey: PlayerSettings.Language.preferredAudioLanguagesKey)
            #expect(PlayerLanguageOptions.load(from: defaults).preferredAudioLanguages.isEmpty)
        }
    }
}

struct PreferredLanguageListTests {
    @Test func `encode and decode round-trip`() {
        let list = ["de", "en", "ja"]
        #expect(PreferredLanguageList.encode(list) == "de,en,ja")
        #expect(PreferredLanguageList.decode("de,en,ja") == list)
    }

    @Test func `an empty list encodes and decodes to nothing`() {
        #expect(PreferredLanguageList.encode([]) == "")
        #expect(PreferredLanguageList.decode("") == [])
    }

    @Test func `decode trims whitespace around each token`() {
        #expect(PreferredLanguageList.decode(" de , en ,\tja ") == ["de", "en", "ja"])
    }

    @Test func `decode drops empty tokens`() {
        #expect(PreferredLanguageList.decode(",de,,en,") == ["de", "en"])
        #expect(PreferredLanguageList.decode("  ,  ") == [])
    }

    @Test func `normalized dedupes case-insensitively, keeping the first spelling`() {
        #expect(PreferredLanguageList.normalized(["de", "DE", "De"]) == ["de"])
        #expect(PreferredLanguageList.normalized(["EN", "de", "en"]) == ["EN", "de"])
    }

    @Test func `normalized preserves the given order`() {
        #expect(PreferredLanguageList.normalized(["ja", "de", "en"]) == ["ja", "de", "en"])
    }

    @Test func `encode normalizes what it stores`() {
        #expect(PreferredLanguageList.encode([" de ", "DE", "", "en"]) == "de,en")
    }
}

/// The feature's user-facing literals. `String(localized:)` can't prove a key
/// is in the catalog — an English key resolves to itself either way — so the
/// catalog is read directly.
struct PreferredLanguageStringsTests {
    private static let expectedLanguages: Set<String> = ["de", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"]

    /// Keys the preferred-language feature added.
    private static let addedKeys = [
        "Audio Languages",
        "Preferred Order",
        "No Preferred Languages",
        "Add Language",
        "Common Languages",
        "Suggested",
        "No Languages Found",
        "Search to find any other language.",
        "Remove %@",
        "Audio Track",
        "Lume selects the first of these languages the stream offers as an audio track. Drag to reorder. "
            + "When the audio that plays is in none of them and the stream carries a forced subtitle track, "
            + "that track is turned on. Applied the next time playback starts.",
        "Lume selects the first of these languages the stream offers as an audio track, most preferred at the top. "
            + "When the audio that plays is in none of them and the stream carries a forced subtitle track, "
            + "that track is turned on. Applied the next time playback starts."
    ]

    /// Keys the feature reuses deliberately rather than adding near-duplicates.
    private static let reusedKeys = [
        "Languages",
        "Search languages",
        "Automatic",
        "Default",
        "Subtitles",
        "Off",
        "Any",
        "Move %@ up",
        "Move %@ down"
    ]

    private static var allKeys: [String] {
        addedKeys + reusedKeys
    }

    @Test func `literals resolve to a non empty string`() {
        for key in Self.allKeys {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
        }
    }

    @Test func `literals are translated in every locale`() throws {
        let catalog = try StringCatalog.localizable()
        for key in Self.allKeys {
            let localizations = try #require(catalog.localizations(for: key), "\(key) is not in the catalog")
            #expect(
                Self.expectedLanguages.isSubset(of: Set(localizations.keys)),
                "\(key) is missing locales: \(Self.expectedLanguages.subtracting(localizations.keys).sorted())"
            )
            for (language, value) in localizations {
                #expect(!value.isEmpty, "\(key) is untranslated in \(language)")
            }
        }
    }
}
