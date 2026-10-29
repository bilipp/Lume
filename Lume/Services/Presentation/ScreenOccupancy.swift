//
//  ScreenOccupancy.swift
//  Lume
//
//  What is on screen over the browse root, for the alerts and sheets raised
//  there: the rating prompt, the Lume Cloud notices and the pairing sheet.
//  None of them can see the players, paywalls and sheets they must not land
//  over — those are presented from call sites all over the app — so each of
//  those reports itself here.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class ScreenOccupancy {
    static let shared = ScreenOccupancy()

    /// How many full-screen players are on screen. A count, not a flag: on
    /// macOS the player is its own `WindowGroup` and on iPadOS the app can run
    /// several scenes, so two can be open at once and closing one must not
    /// report the screen as clear while the other is still playing.
    private var openPlayerCount = 0

    /// Whether any full-screen player is on screen. The root can't infer this
    /// from its own presentation state: on macOS the player is a separate
    /// `WindowGroup`, so the browse UI stays visible for the whole movie.
    var playerIsVisible: Bool {
        openPlayerCount > 0
    }

    /// How many paywalls are on screen. Counted the same way and for the same
    /// reason as players: `paywall(isPresented:)` has a dozen call sites, and
    /// the browse root can see none of them.
    private var openPaywallCount = 0

    /// Whether a paywall is on screen right now.
    var paywallIsVisible: Bool {
        openPaywallCount > 0
    }

    /// How many blocking sheets that the browse root cannot see are on screen.
    /// Counted the same way as players and paywalls: Settings is raised from
    /// the library toolbar, so the tab root has no binding for it. The root
    /// alerts above the browse root count here too, while they are up.
    private var openBlockingSheetCount = 0

    /// Whether such a sheet is on screen right now.
    var blockingSheetIsVisible: Bool {
        openBlockingSheetCount > 0
    }

    /// The browse roots with a presentation of their own up: the sync cover,
    /// downloads, the add-device sheet, a playlist or profile switch. Reported
    /// by `MainTabView`, the only view that can see them. A set, one entry per
    /// window: iPadOS, macOS and visionOS run a browse root in every window.
    private var coveredBrowseRoots: Set<UUID> = []

    /// Whether any browse root has a presentation of its own up.
    var browseRootIsCovered: Bool {
        !coveredBrowseRoots.isEmpty
    }

    /// The root notice on screen, or claimed to go up. Every window raises the
    /// root notices, so only the one holding this shows them.
    private var rootNoticeOwner: UUID?

    /// Whether anything blocking is on screen. The one check for every alert
    /// raised at the root, so none lands over a player, a paywall or a sheet.
    var isScreenBusy: Bool {
        playerIsVisible || paywallIsVisible || blockingSheetIsVisible || browseRootIsCovered
    }

    /// `isScreenBusy` without the browse root's own presentations, for one the
    /// root raises itself and so already counts in `browseRootIsCovered`.
    /// Players are left out where they open in their own window (macOS), so
    /// they don't cover the browse root's.
    var coversBrowseRoot: Bool {
        #if os(macOS)
            paywallIsVisible || blockingSheetIsVisible
        #else
            playerIsVisible || paywallIsVisible || blockingSheetIsVisible
        #endif
    }

    /// What holds back an alert raised at the root: `coversBrowseRoot` plus
    /// the browse root's own presentations.
    var isRootAlertBlocked: Bool {
        coversBrowseRoot || browseRootIsCovered
    }

    // MARK: - Players

    /// A full-screen player or Multi-View grid opened. Multi-View reports
    /// itself too, from inside `MultiViewScreen`: its presentation sites are
    /// invisible to the browse root.
    func notePlayerAppeared() {
        openPlayerCount += 1
    }

    /// A full-screen player or Multi-View grid closed.
    func notePlayerDisappeared() {
        openPlayerCount = max(0, openPlayerCount - 1)
    }

    // MARK: - Paywall

    func notePaywallAppeared() {
        openPaywallCount += 1
    }

    func notePaywallDismissed() {
        openPaywallCount = max(0, openPaywallCount - 1)
    }

    // MARK: - Blocking sheets

    /// A sheet the browse root cannot see was presented over it — Settings,
    /// which presents sheets of its own several levels down (add playlist,
    /// playlist sync, the debug mail and share sheets) that not even Settings'
    /// own presenter can see.
    func noteBlockingSheetAppeared() {
        openBlockingSheetCount += 1
    }

    /// That sheet was dismissed.
    func noteBlockingSheetDismissed() {
        openBlockingSheetCount = max(0, openBlockingSheetCount - 1)
    }

    // MARK: - Browse root

    /// One browse root's own presentations came up or went away.
    func noteBrowseRootCovered(_ covered: Bool, by root: UUID) {
        if covered {
            coveredBrowseRoots.insert(root)
        } else {
            coveredBrowseRoots.remove(root)
        }
    }

    // MARK: - Root notices

    /// Whether `notice` may go up: no other window's notice holds the screen.
    func canRaiseRootNotice(_ notice: UUID) -> Bool {
        rootNoticeOwner == nil || rootNoticeOwner == notice
    }

    /// Takes the screen for `notice`; false when another notice holds it.
    func claimRootNotice(_ notice: UUID) -> Bool {
        guard canRaiseRootNotice(notice) else { return false }
        rootNoticeOwner = notice
        return true
    }

    func releaseRootNotice(_ notice: UUID) {
        if rootNoticeOwner == notice {
            rootNoticeOwner = nil
        }
    }
}

extension View {
    /// Reports whether the browse root has a presentation of its own on screen
    /// to `ScreenOccupancy`, which the root alerts above it read.
    func reportsBrowseRootCovered(_ covered: Bool) -> some View {
        modifier(BrowseRootCoverReporter(covered: covered))
    }
}

private struct BrowseRootCoverReporter: ViewModifier {
    let covered: Bool
    @State private var root = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: covered, initial: true) { _, covered in
                ScreenOccupancy.shared.noteBrowseRootCovered(covered, by: root)
            }
            .onDisappear {
                ScreenOccupancy.shared.noteBrowseRootCovered(false, by: root)
            }
    }
}
