@testable import Lume
import Testing

struct PlayerAudioChannelPreferenceTests {
    @Test func `a stereo source stays stereo on a surround route`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 2, routeMaximum: 8) == 2)
        #expect(PlayerAudioChannelPreference.channels(forSource: 2, routeMaximum: 6) == 2)
    }

    @Test func `a surround source asks for its own width`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 6, routeMaximum: 8) == 6)
        #expect(PlayerAudioChannelPreference.channels(forSource: 8, routeMaximum: 8) == 8)
    }

    @Test func `the route caps what a source can ask for`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 8, routeMaximum: 6) == 6)
        #expect(PlayerAudioChannelPreference.channels(forSource: 6, routeMaximum: 2) == 2)
        #expect(PlayerAudioChannelPreference.channels(forSource: 2, routeMaximum: 1) == 1)
        #expect(PlayerAudioChannelPreference.channels(forSource: 2, routeMaximum: 0) == 1)
    }

    @Test func `a mono source asks for stereo`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 1, routeMaximum: 8) == 2)
    }

    @Test func `an unknown source asks for stereo`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: nil, routeMaximum: 8) == 2)
        #expect(PlayerAudioChannelPreference.channels(forSource: 0, routeMaximum: 8) == 2)
    }
}
