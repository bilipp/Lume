//
//  SportCatalog.swift
//  Lume
//
//  A curated, offline list of the football leagues and cups users can follow,
//  so the Sports settings screen has something to show before (or without) any
//  network call. European competitions are listed first, as they're the focus
//  of the Upcoming Matches feature. The ids are TheSportsDB league ids, used to
//  fetch fixtures and to browse a league's teams.
//

import Foundation

/// One selectable league/cup in the Sports settings picker.
nonisolated struct SportLeague: Identifiable, Hashable {
    /// TheSportsDB league id.
    let id: String
    let name: String
    /// Country / confederation, shown as a subtitle and used to group the list.
    let region: String
}

nonisolated enum SportCatalog {
    /// The leagues offered in settings, in display order. European domestic
    /// leagues and UEFA cups come first (the feature's priority), followed by a
    /// few widely-followed leagues from other regions.
    static let leagues: [SportLeague] = [
        // UEFA club competitions
        SportLeague(id: "4480", name: "UEFA Champions League", region: "Europe"),
        SportLeague(id: "4481", name: "UEFA Europa League", region: "Europe"),
        // England
        SportLeague(id: "4328", name: "Premier League", region: "England"),
        SportLeague(id: "4329", name: "Championship", region: "England"),
        SportLeague(id: "4482", name: "FA Cup", region: "England"),
        // Spain
        SportLeague(id: "4335", name: "La Liga", region: "Spain"),
        // Germany
        SportLeague(id: "4331", name: "Bundesliga", region: "Germany"),
        // Italy
        SportLeague(id: "4332", name: "Serie A", region: "Italy"),
        // France
        SportLeague(id: "4334", name: "Ligue 1", region: "France"),
        // Netherlands
        SportLeague(id: "4337", name: "Eredivisie", region: "Netherlands"),
        // Portugal
        SportLeague(id: "4344", name: "Primeira Liga", region: "Portugal"),
        // Scotland
        SportLeague(id: "4330", name: "Scottish Premiership", region: "Scotland"),
        // Rest of world (kept short; European soccer is the focus)
        SportLeague(id: "4346", name: "Major League Soccer", region: "USA"),
        SportLeague(id: "4350", name: "Brazilian Série A", region: "Brazil")
    ]

    /// Looks up a league by its TheSportsDB id.
    static func league(id: String) -> SportLeague? {
        leagues.first { $0.id == id }
    }
}
