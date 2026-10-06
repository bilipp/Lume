//
//  LiveTVToolbarLayout.swift
//  Lume
//
//  Whether the Live TV toolbar has room for Recordings and Multi-View as two
//  buttons, or folds them into one menu. Pure arithmetic over the measured
//  iOS 26 Liquid Glass bar, so the decision is unit-tested; the view only
//  feeds it text widths and its own width.
//

import CoreGraphics

/// How the Recordings / Multi-View cluster appears in the Live TV toolbar.
nonisolated enum LiveTVToolbarClusterLayout: Equatable {
    /// Neither button is visible.
    case hidden
    /// The visible buttons, each its own toolbar item.
    case separate(recordings: Bool, multiView: Bool)
    /// Both buttons, folded into one menu.
    case combined

    /// Folds the pair only when both would show and the bar is cramped — a
    /// single button gains nothing from a menu.
    init(showsRecordings: Bool, showsMultiView: Bool, isCramped: Bool) {
        switch (showsRecordings, showsMultiView) {
        case (false, false):
            self = .hidden
        case (true, true) where isCramped:
            self = .combined
        default:
            self = .separate(recordings: showsRecordings, multiView: showsMultiView)
        }
    }
}

/// The room the Live TV toolbar needs on iPhone and iPad, and the narrowest
/// Live TV view that still fits the cluster as two separate buttons beside the
/// library buttons (sort, Sync, Settings, and the playlist switcher when there
/// is more than one playlist).
///
/// When the trailing items outgrow the bar, UIKit moves the surplus into a
/// `•••` overflow: on iPhone, Sync and Settings go first; on an iPad, whose
/// tab bar floats in the middle of the bar, the cluster itself splits and
/// Multi-View lands in the overflow. Below `crampedBelowWidth` the two buttons
/// fold into one menu, which saves one button and stays visible as the
/// leading trailing item.
///
/// The figures are measured on iOS / iPadOS 26.5 (Liquid Glass bar): a capsule
/// of n buttons is `35 + 42n` pt wide, groups are 12 pt apart (the fixed
/// `ToolbarSpacer`), the bar keeps 16 pt margins on iPhone, and an iPad's
/// trailing items keep 30 pt off the tab bar and 11 pt off the edge. The top
/// tab bar is its titles' widths plus 33 pt a tab plus 59 pt (Search and the
/// capsule's insets) — within 1 pt of the English, French and German bars.
/// Checked against the real bar: with one playlist an iPhone 17e or 17 Pro
/// fits both buttons, and with a switcher neither does; an iPhone Pro Max
/// (440 pt) fits them beside a switcher titled "test" but not "My IPTV". An
/// iPad's top bar needs about 1,150 pt, so 11" and 13" iPads fold the pair in
/// portrait and keep two buttons in landscape (1,180 pt and wider).
nonisolated struct LiveTVToolbarSpace: Hashable {
    /// Whether the tab bar floats in the navigation bar (an iPad in a
    /// regular-width window). Otherwise it sits at the bottom, as on iPhone
    /// and in a compact iPad window, and the inline title yields to the items.
    var tabBarOnTop: Bool
    /// Widths of the top tab bar's titled tabs at 17 pt (Search is an icon).
    var tabTitleWidths: [CGFloat] = []
    /// Width of the playlist switcher's title, or nil when it isn't shown.
    var switcherTitleWidth: CGFloat?

    static let buttonPitch: CGFloat = 42
    static let capsuleInsets: CGFloat = 35
    static let groupSpacing: CGFloat = 12
    static let compactMargins: CGFloat = 2 * 16
    static let topTabBarGap: CGFloat = 30
    static let topTrailingMargin: CGFloat = 11
    static let tabTitleInsets: CGFloat = 33
    static let tabBarInsets: CGFloat = 59
    /// `PlaylistSwitcher`'s label cap, and what its label adds to the title
    /// (spacing and chevron) and the toolbar adds around it.
    static let switcherLabelCap: CGFloat = 150
    static let switcherChevron: CGFloat = 15
    static let switcherInsets: CGFloat = 36

    /// The library capsule's buttons: sort, Sync, Settings.
    static let libraryButtons = 3

    static func capsule(buttons: Int) -> CGFloat {
        capsuleInsets + CGFloat(buttons) * buttonPitch
    }

    var switcherWidth: CGFloat {
        guard let switcherTitleWidth else { return 0 }
        return min(Self.switcherLabelCap, switcherTitleWidth + Self.switcherChevron) + Self.switcherInsets
    }

    /// The trailing items' width with Recordings and Multi-View as two buttons.
    var separateItemsWidth: CGFloat {
        Self.capsule(buttons: 2) + Self.groupSpacing + Self.capsule(buttons: Self.libraryButtons) + switcherWidth
    }

    var topTabBarWidth: CGFloat {
        tabTitleWidths.reduce(0, +) + CGFloat(tabTitleWidths.count) * Self.tabTitleInsets + Self.tabBarInsets
    }

    /// The narrowest Live TV view (pt) that fits the separate buttons without
    /// an overflow. The top tab bar is centred, so the trailing items get half
    /// of what it leaves.
    var crampedBelowWidth: CGFloat {
        if tabBarOnTop {
            topTabBarWidth + 2 * (Self.topTabBarGap + separateItemsWidth + Self.topTrailingMargin)
        } else {
            separateItemsWidth + Self.compactMargins
        }
    }

    func isCramped(width: CGFloat) -> Bool {
        width > 0 && width < crampedBelowWidth
    }
}
