//
//  HomeView+Sports.swift
//  Lume
//
//  Home's side of the Sports Hub: whether the Sports rail has anything to render
//  (the empty-state check shares `SportsRailPlanner` with the rail itself) and
//  the warm that keeps it fed.
//
//  The warm lives on Home rather than inside `SportsHomeRail` on purpose. The
//  rail renders nothing at all while a followed league has no fixtures — which
//  is exactly the state that needs a fetch — so its own `onAppear` never fires
//  there and the row stayed empty for the whole session unless the viewer found
//  Settings › Sports › Refresh Now. Home is always on screen; the warm is keyed
//  so it re-runs when the entitlement or the followed set finally lands.
//

import SwiftUI

extension HomeView {
    /// Re-runs the Sports warm whenever something that could unblock it changes:
    /// the entitlement resolving (StoreKit answers after the first render), the
    /// followed set arriving (iCloud reconcile, profile switch) or the row being
    /// switched on.
    var sportsWarmKey: String {
        guard isSectionEnabled(.sports), premium.isPremium else { return "off" }
        return sportsFollows.follows.map(\.key).joined(separator: ",")
    }

    /// Loads the cached snapshots and asks for anything missing or stale — the
    /// same three triggers the Sports tab runs on appear.
    func warmSports() {
        guard isSectionEnabled(.sports), premium.isPremium else { return }
        sportsStore.loadCached(
            leagueIds: SportsRailPlanner.displayLeagueIds(for: sportsFollows.follows)
        )
        SportsSyncService.shared.syncIfDue()
        SportsSyncService.shared.refreshMissing()
        SportsSyncService.shared.catchUpIfStale()
    }

    /// Whether the Sports rail would render anything — the same rule the rail
    /// itself applies (`SportsRailPlanner`), so a viewer whose only Home content
    /// is followed-team fixtures (or the onboarding card) never sees the empty state.
    var sportsRailHasContent: Bool {
        let lockedRowShown = true
        guard isSectionEnabled(.sports) else { return false }
        return SportsRailPlanner.hasContent(
            isPremium: premium.isPremium,
            follows: sportsFollows.follows,
            store: sportsStore,
            lockedRowShown: lockedRowShown
        )
    }
}
