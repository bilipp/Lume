import Foundation
@testable import Lume
import Testing

struct PlayerSettingsTests {
    @Test func `engine kind all cases`() {
        #expect(PlayerEngineKind.allCases.count == 5)
        #expect(PlayerEngineKind.lumeEngine.rawValue == "lumeEngine")
        #expect(PlayerEngineKind.aetherEngine.rawValue == "aetherEngine")
        #expect(PlayerEngineKind.vlcKit.rawValue == "vlcKit")
        #expect(PlayerEngineKind.ksPlayer.rawValue == "ksPlayer")
        #expect(PlayerEngineKind.avPlayer.rawValue == "avPlayer")
    }

    @Test func `engine kind display names`() {
        #expect(PlayerEngineKind.vlcKit.displayName == "VLCKit")
        #expect(PlayerEngineKind.ksPlayer.displayName == "KSPlayer")
        #expect(PlayerEngineKind.lumeEngine.displayName == "Lume Engine (Beta)")
        #expect(PlayerEngineKind.aetherEngine.displayName == "AetherEngine")
        #expect(PlayerEngineKind.avPlayer.displayName == "AVPlayer")
    }

    @Test func `engine kind identifiable`() {
        #expect(PlayerEngineKind.vlcKit.id == "vlcKit")
        #expect(PlayerEngineKind.ksPlayer.id == "ksPlayer")
        #expect(PlayerEngineKind.lumeEngine.id == "lumeEngine")
        #expect(PlayerEngineKind.aetherEngine.id == "aetherEngine")
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
        #expect(PlayerEngineKind.aetherEngine.rendersOwnControls)
    }

    @Test func `engine storage key`() {
        #expect(PlayerSettings.engineKey == "player.engine")
    }

    @Test func `engine priority storage key`() {
        #expect(PlayerSettings.enginePriorityKey == "player.enginePriority")
    }

    @Test func `guide preview mode storage key and default`() {
        #expect(PlayerSettings.tvGuidePreviewModeKey == "player.tvGuidePreviewMode")
        #expect(PlayerSettings.tvGuidePreviewModeDefault == .small)
    }

    @Test func `guide preview mode reads the default until a value is stored`() throws {
        let name = "PlayerSettingsTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let defaults = try #require(UserDefaults(suiteName: name))
        let key = PlayerSettings.tvGuidePreviewModeKey
        #expect(GuidePreviewMode(storedValue: defaults.string(forKey: key)) == .small)
        defaults.set(GuidePreviewMode.large.rawValue, forKey: key)
        #expect(GuidePreviewMode(storedValue: defaults.string(forKey: key)) == .large)
        defaults.set("bogus", forKey: key)
        #expect(GuidePreviewMode(storedValue: defaults.string(forKey: key)) == .small)
    }

    @Test func `live quality switch storage key and default`() {
        #expect(PlayerSettings.Playback.liveQualitySwitchKey == "player.liveQualitySwitch")
        #expect(PlayerSettings.Playback.liveQualitySwitchDefault == false)
    }

    @Test func `volume reads the default until a value is stored, clamped`() {
        #expect(PlayerSettings.volumeKey == "player.volume")
        withIsolatedDefaults { defaults in
            #expect(PlayerSettings.volume(in: defaults) == 1.0)
            defaults.set(Float(0.4), forKey: PlayerSettings.volumeKey)
            #expect(PlayerSettings.volume(in: defaults) == 0.4)
            defaults.set(Float(0), forKey: PlayerSettings.volumeKey)
            #expect(PlayerSettings.volume(in: defaults) == 0)
            defaults.set(Float(3), forKey: PlayerSettings.volumeKey)
            #expect(PlayerSettings.volume(in: defaults) == 1)
            defaults.set(Float(-2), forKey: PlayerSettings.volumeKey)
            #expect(PlayerSettings.volume(in: defaults) == 0)
        }
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
        // the opt-in LumeEngine and AetherEngine always land at the end.
        #expect(deduped == [.avPlayer, .vlcKit, .ksPlayer, .lumeEngine, .aetherEngine])
        // A complete list is returned unchanged.
        let complete: [PlayerEngineKind] = [.ksPlayer, .avPlayer, .vlcKit, .aetherEngine, .lumeEngine]
        #expect(PlayerEnginePriority.normalized(complete) == complete)
        // Every engine always appears exactly once.
        #expect(Set(PlayerEnginePriority.normalized([])) == Set(PlayerEngineKind.allCases))
        #expect(PlayerEnginePriority.normalized([]).count == PlayerEngineKind.allCases.count)
    }

    @Test func `resolve uses the stored priority when present`() {
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "ksPlayer,avPlayer,vlcKit",
            legacyEngineRaw: PlayerEngineKind.vlcKit.rawValue
        )
        #expect(resolved == [.ksPlayer, .avPlayer, .vlcKit, .lumeEngine, .aetherEngine])
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

    @Test func `default priority is KSPlayer then VLCKit then AVPlayer, opt-in engines last`() {
        #expect(PlayerEngineKind.defaultValue == .ksPlayer)
        // A fresh install (no stored priority, engine key defaults to the default
        // engine) resolves to the documented default order, with LumeEngine
        // and AetherEngine appended last as opt-ins.
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "",
            legacyEngineRaw: PlayerEngineKind.defaultValue.rawValue
        )
        #expect(resolved == [.ksPlayer, .vlcKit, .avPlayer, .lumeEngine, .aetherEngine])
    }

    @Test func `a stored priority from before AetherEngine keeps KSPlayer first and appends Aether last`() {
        let resolved = PlayerEnginePriority.resolve(
            priorityRaw: "ksPlayer,vlcKit,avPlayer,lumeEngine",
            legacyEngineRaw: PlayerEngineKind.ksPlayer.rawValue
        )
        #expect(resolved.first == .ksPlayer)
        #if os(visionOS)
            #expect(resolved == [.ksPlayer, .vlcKit, .avPlayer, .lumeEngine])
        #else
            #expect(resolved == [.ksPlayer, .vlcKit, .avPlayer, .lumeEngine, .aetherEngine])
        #endif
    }

    @Test func `available engines match the platform`() {
        #if os(visionOS)
            #expect(PlayerEngineKind.available == [.vlcKit, .ksPlayer, .avPlayer, .lumeEngine])
            #expect(!PlayerEnginePriority.normalized([.aetherEngine, .ksPlayer]).contains(.aetherEngine))
        #else
            #expect(PlayerEngineKind.available == PlayerEngineKind.allCases)
            #expect(PlayerEnginePriority.normalized([.aetherEngine]).first == .aetherEngine)
        #endif
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
    private static let expectedLanguages: Set<String> = ["ar", "de", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"]

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
