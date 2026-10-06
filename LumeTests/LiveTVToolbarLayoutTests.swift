import CoreGraphics
@testable import Lume
import Testing

struct LiveTVToolbarClusterLayoutTests {
    @Test func `both buttons on a cramped bar fold into one menu`() {
        #expect(LiveTVToolbarClusterLayout(showsRecordings: true, showsMultiView: true, isCramped: true) == .combined)
    }

    @Test func `both buttons stay separate when the bar has room`() {
        #expect(
            LiveTVToolbarClusterLayout(showsRecordings: true, showsMultiView: true, isCramped: false)
                == .separate(recordings: true, multiView: true)
        )
    }

    @Test(arguments: [true, false])
    func `a single button never folds into a menu`(isCramped: Bool) {
        #expect(
            LiveTVToolbarClusterLayout(showsRecordings: true, showsMultiView: false, isCramped: isCramped)
                == .separate(recordings: true, multiView: false)
        )
        #expect(
            LiveTVToolbarClusterLayout(showsRecordings: false, showsMultiView: true, isCramped: isCramped)
                == .separate(recordings: false, multiView: true)
        )
    }

    @Test(arguments: [true, false])
    func `no buttons hide the cluster`(isCramped: Bool) {
        #expect(LiveTVToolbarClusterLayout(showsRecordings: false, showsMultiView: false, isCramped: isCramped) == .hidden)
    }
}

/// The widths below are the ones the simulators measured (iOS / iPadOS 26.5),
/// so each case pins a bar that was seen to fit or to overflow.
struct LiveTVToolbarSpaceTests {
    /// "Home", "Movies", "Series", "Live TV", "Sports" at 17 pt.
    private let englishTabs: [CGFloat] = [45, 57, 50, 56, 52]

    @Test func `an iPhone with one playlist keeps both buttons`() {
        let space = LiveTVToolbarSpace(tabBarOnTop: false)
        #expect(!space.isCramped(width: 402)) // iPhone 17 Pro
        #expect(!space.isCramped(width: 390)) // iPhone 17e
    }

    @Test func `a playlist switcher crowds an iPhone`() {
        let short = LiveTVToolbarSpace(tabBarOnTop: false, switcherTitleWidth: 31) // "test"
        #expect(short.isCramped(width: 402))
        #expect(!short.isCramped(width: 440)) // iPhone Pro Max

        let longer = LiveTVToolbarSpace(tabBarOnTop: false, switcherTitleWidth: 66) // "My IPTV"
        #expect(longer.isCramped(width: 440))
    }

    @Test func `a long playlist name costs no more than the switcher's cap`() {
        let capped = LiveTVToolbarSpace(tabBarOnTop: false, switcherTitleWidth: 135)
        let longest = LiveTVToolbarSpace(tabBarOnTop: false, switcherTitleWidth: 900)
        #expect(longest.crampedBelowWidth == capped.crampedBelowWidth)
    }

    @Test func `an iPad's top tab bar folds the pair in portrait, not landscape`() {
        let space = LiveTVToolbarSpace(tabBarOnTop: true, tabTitleWidths: englishTabs)
        #expect(space.isCramped(width: 820)) // 11" portrait
        #expect(space.isCramped(width: 1024)) // 13" portrait
        #expect(!space.isCramped(width: 1180)) // 11" landscape
        #expect(!space.isCramped(width: 1366)) // 13" landscape
    }

    @Test func `a compact iPad window lays out like an iPhone`() {
        #expect(!LiveTVToolbarSpace(tabBarOnTop: false).isCramped(width: 507))
        #expect(LiveTVToolbarSpace(tabBarOnTop: false).isCramped(width: 320))
    }

    @Test func `an unmeasured view is not cramped`() {
        #expect(!LiveTVToolbarSpace(tabBarOnTop: true, tabTitleWidths: englishTabs).isCramped(width: 0))
    }
}
