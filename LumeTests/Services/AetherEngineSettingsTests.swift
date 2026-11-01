import Foundation
@testable import Lume
import Testing

struct AetherEngineSettingsTests {
    private typealias Keys = PlayerSettings.Aether

    private static let fullScreen = AetherLoadContext(
        isLive: false,
        httpHeaders: nil,
        preferredAudioLanguages: [],
        isEmbedded: false,
        honorsMatchContentToggle: true
    )

    @Test func `keys live under player aether and are unique`() {
        #expect(Keys.allKeys.count == 15)
        #expect(Set(Keys.allKeys).count == Keys.allKeys.count)
        #expect(Keys.allKeys.allSatisfy { $0.hasPrefix("player.aether.") })
        #expect(Keys.matchContentKey == "player.aether.matchContent")
        #expect(Keys.nativeRemoteHLSKey == "player.aether.nativeRemoteHLS")
    }

    @Test func `untouched defaults load the documented values`() {
        withIsolatedDefaults { defaults in
            let options = AetherEngineOptions.load(from: defaults)
            #expect(options.decodePath == .automatic)
            #expect(options.escalateToSoftware)
            #expect(options.deinterlaceMode == .auto)
            #expect(options.deinterlaceFieldRate == .field)
            #expect(options.liveJoinProfile == .standard)
            #expect(options.forwardBufferSegments == 0)
            #expect(options.probeSize == .auto)
            #expect(options.analyzeDuration == .auto)
            #expect(options.nativeRemoteHLS)
            #expect(options.audioBridgeMode == .surroundCompat)
            #expect(options.dynamicRange == .automatic)
            #expect(!options.upscaleLowResolution)
            #expect(options.audioDelay == 0)
            #expect(!options.prepareNativeSubtitles)
            #expect(options.matchContent)
        }
    }

    @Test func `stored values load, and unknown raw values fall back`() {
        withIsolatedDefaults { defaults in
            defaults.set("software", forKey: Keys.decodePathKey)
            defaults.set(false, forKey: Keys.escalateToSoftwareKey)
            defaults.set("fastZap", forKey: Keys.liveJoinProfileKey)
            defaults.set(40, forKey: Keys.forwardBufferSegmentsKey)
            defaults.set(5, forKey: Keys.probeSizeKey)
            defaults.set(2, forKey: Keys.analyzeDurationKey)
            defaults.set("lossless", forKey: Keys.audioBridgeModeKey)
            defaults.set("baseLayerOnly", forKey: Keys.dynamicRangeKey)
            defaults.set(-150, forKey: Keys.audioDelayKey)
            defaults.set("bogus", forKey: Keys.deinterlaceModeKey)
            let options = AetherEngineOptions.load(from: defaults)
            #expect(options.decodePath == .software)
            #expect(!options.escalateToSoftware)
            #expect(options.liveJoinProfile == .fastZap)
            #expect(options.forwardBufferSegments == 40)
            #expect(options.probeSize == .fiveMB)
            #expect(options.analyzeDuration == .twoSeconds)
            #expect(options.audioBridgeMode == .lossless)
            #expect(options.dynamicRange == .baseLayerOnly)
            #expect(options.audioDelay == -150)
            #expect(options.deinterlaceMode == .auto)
        }
    }

    @Test func `reset clears every stored option`() {
        withIsolatedDefaults { defaults in
            for key in Keys.allKeys {
                defaults.set("x", forKey: key)
            }
            Keys.resetToDefaults(in: defaults)
            #expect(Keys.allKeys.allSatisfy { defaults.object(forKey: $0) == nil })
            #expect(AetherEngineOptions.load(from: defaults).matchContent)
        }
    }

    @Test func `full-screen mapping carries the options and the media`() {
        withIsolatedDefaults { defaults in
            defaults.set(20, forKey: Keys.forwardBufferSegmentsKey)
            defaults.set(10, forKey: Keys.probeSizeKey)
            defaults.set(5, forKey: Keys.analyzeDurationKey)
            defaults.set(250, forKey: Keys.audioDelayKey)
            defaults.set(true, forKey: Keys.upscaleLowResolutionKey)
            defaults.set(true, forKey: Keys.prepareNativeSubtitlesKey)
            var context = Self.fullScreen
            context.isLive = true
            context.httpHeaders = ["X-Test": "1"]
            context.preferredAudioLanguages = ["de", "en"]
            let plan = AetherLoadPlan.make(options: .load(from: defaults), context: context)
            #expect(plan.isLive)
            #expect(plan.httpHeaders == ["X-Test": "1"])
            #expect(plan.preferredAudioLanguages == ["de", "en"])
            #expect(plan.forwardBufferSegments == 20)
            #expect(plan.probesize == Int64(10 * 1_048_576))
            #expect(plan.maxAnalyzeDuration == Int64(5_000_000))
            #expect(plan.audioDelaySeconds == 0.25)
            #expect(plan.upscalesLowResolutionVideo)
            #expect(plan.prepareNativeSubtitles)
            #expect(plan.nativeRemoteHLS)
            #expect(plan.matchContentEnabled)
            #expect(plan.sharedOutputRole == .primary)
        }
    }

    @Test func `engine defaults map to nil`() {
        withIsolatedDefaults { defaults in
            let plan = AetherLoadPlan.make(options: .load(from: defaults), context: Self.fullScreen)
            #expect(plan.httpHeaders.isEmpty)
            #expect(plan.forwardBufferSegments == nil)
            #expect(plan.probesize == nil)
            #expect(plan.maxAnalyzeDuration == nil)
            #expect(plan.audioDelaySeconds == 0)
        }
    }

    @Test func `embedded loads are secondary and never match content`() {
        withIsolatedDefaults { defaults in
            var context = Self.fullScreen
            context.isEmbedded = true
            let plan = AetherLoadPlan.make(options: .load(from: defaults), context: context)
            #expect(!plan.matchContentEnabled)
            #expect(plan.sharedOutputRole == .secondary)
        }
    }

    @Test func `match content off disables display criteria where the toggle applies`() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: Keys.matchContentKey)
            let options = AetherEngineOptions.load(from: defaults)
            #expect(!AetherLoadPlan.make(options: options, context: Self.fullScreen).matchContentEnabled)

            var elsewhere = Self.fullScreen
            elsewhere.honorsMatchContentToggle = false
            #expect(AetherLoadPlan.make(options: options, context: elsewhere).matchContentEnabled)
        }
    }

    @Test func `preset labels`() {
        #expect(AetherForwardBufferPreset.values.first == 0)
        #expect(AetherAudioDelayPreset.label(100) == "+100 ms")
        #expect(AetherAudioDelayPreset.label(-50) == "-50 ms")
        #expect(AetherProbeSize.twoMB.label == "2 MB")
    }
}
