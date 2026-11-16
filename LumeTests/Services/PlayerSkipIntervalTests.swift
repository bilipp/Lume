import Foundation
@testable import Lume
import Testing

struct PlayerSkipIntervalTests {
    @Test func `every option keeps its value and has matching symbols`() {
        for seconds in PlayerSkipInterval.options {
            let interval = PlayerSkipInterval(seconds: seconds)
            #expect(interval.seconds == seconds)
            #expect(interval.timeInterval == TimeInterval(seconds))
            #expect(interval.backwardSymbol == "gobackward.\(seconds)")
            #expect(interval.forwardSymbol == "goforward.\(seconds)")
        }
    }

    @Test func `the platform default is one of the options`() {
        #expect(PlayerSkipInterval.options.contains(PlayerSkipInterval.platformDefault))
    }

    @Test(arguments: [0, -10, 7, 20, 120])
    func `an unset or unknown value falls back to the platform default`(raw: Int) {
        #expect(PlayerSkipInterval(seconds: raw).seconds == PlayerSkipInterval.platformDefault)
    }

    @Test func `stored reads the setting and falls back when it is missing`() throws {
        let suite = "PlayerSkipIntervalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PlayerSkipInterval.stored(in: defaults).seconds == PlayerSkipInterval.platformDefault)

        defaults.set(30, forKey: PlayerSettings.Playback.skipIntervalKey)
        #expect(PlayerSkipInterval.stored(in: defaults).seconds == 30)

        defaults.set(42, forKey: PlayerSettings.Playback.skipIntervalKey)
        #expect(PlayerSkipInterval.stored(in: defaults).seconds == PlayerSkipInterval.platformDefault)
    }
}
