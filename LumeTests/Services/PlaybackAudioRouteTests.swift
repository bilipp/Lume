import Foundation
@testable import Lume
import Testing

@MainActor
struct PlaybackAudioRouteTests {
    @Test func `a stereo route states nothing and lets the engine default stand`() {
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 2, maximum: 2) == nil)
    }

    @Test func `a granted 5 point 1 route states six, never the hardware maximum`() {
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 6, maximum: 8) == 6)
    }

    @Test func `an ungranted widening request stays stereo rather than over-shooting`() {
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 2, maximum: 8) == nil)
    }

    @Test func `the granted width is the ceiling`() {
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 8, maximum: 8) == 8)
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 64, maximum: 8) == 8)
    }

    @Test func `absurd inputs resolve to nothing stated`() {
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 0, maximum: 0) == nil)
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: -3, maximum: 8) == nil)
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 6, maximum: 0) == nil)
        #expect(PlaybackAudioRoute.negotiatedWidth(granted: 3, maximum: 8) == 3)
    }

    @Test func `an output device with no streams states nothing`() {
        #expect(PlaybackAudioRoute.totalChannels(inBufferCounts: []) == 0)
        #expect(PlaybackAudioRoute.deviceWidth(inBufferCounts: []) == nil)
    }

    @Test func `a stereo output device states nothing`() {
        #expect(PlaybackAudioRoute.deviceWidth(inBufferCounts: [2]) == nil)
    }

    @Test func `channels sum across every output stream of the device`() {
        #expect(PlaybackAudioRoute.totalChannels(inBufferCounts: [2, 2, 2]) == 6)
        #expect(PlaybackAudioRoute.deviceWidth(inBufferCounts: [2, 2, 2]) == 6)
    }

    @Test func `a single wide stream states its full width`() {
        #expect(PlaybackAudioRoute.deviceWidth(inBufferCounts: [8]) == 8)
    }
}
