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
    /// TheSportsDB league id, used to fetch upcoming fixtures (`eventsnextleague`).
    let id: String
    let name: String
    /// TheSportsDB's canonical league name, used to browse a league's teams via
    /// `search_all_teams.php?l=` — the `lookup_all_teams.php?id=` endpoint is
    /// demo-locked on the free key and ignores the id.
    let searchName: String
    /// Country / confederation, shown as a subtitle and used to group the list.
    let region: String
}

nonisolated enum SportCatalog {
    /// The leagues offered in settings, in display order. European domestic
    /// leagues and UEFA cups come first (the feature's priority), followed by a
    /// few widely-followed leagues from other regions.
    static let leagues: [SportLeague] = [
        // UEFA club competitions (cups: no fixed team list to browse)
        SportLeague(id: "4480", name: "UEFA Champions League", searchName: "UEFA Champions League", region: "Europe"),
        SportLeague(id: "4481", name: "UEFA Europa League", searchName: "UEFA Europa League", region: "Europe"),
        // England
        SportLeague(id: "4328", name: "Premier League", searchName: "English Premier League", region: "England"),
        SportLeague(id: "4329", name: "Championship", searchName: "English League Championship", region: "England"),
        SportLeague(id: "4482", name: "FA Cup", searchName: "English FA Cup", region: "England"),
        // Spain
        SportLeague(id: "4335", name: "La Liga", searchName: "Spanish La Liga", region: "Spain"),
        // Germany
        SportLeague(id: "4331", name: "Bundesliga", searchName: "German Bundesliga", region: "Germany"),
        // Italy
        SportLeague(id: "4332", name: "Serie A", searchName: "Italian Serie A", region: "Italy"),
        // France
        SportLeague(id: "4334", name: "Ligue 1", searchName: "French Ligue 1", region: "France"),
        // Netherlands
        SportLeague(id: "4337", name: "Eredivisie", searchName: "Dutch Eredivisie", region: "Netherlands"),
        // Portugal
        SportLeague(id: "4344", name: "Primeira Liga", searchName: "Portuguese Primeira Liga", region: "Portugal"),
        // Scotland
        SportLeague(id: "4330", name: "Scottish Premiership", searchName: "Scottish Premier League", region: "Scotland"),
        // Rest of world (kept short; European soccer is the focus)
        SportLeague(id: "4346", name: "Major League Soccer", searchName: "American Major League Soccer", region: "USA"),
        SportLeague(id: "4351", name: "Brazilian Série A", searchName: "Brazilian Serie A", region: "Brazil")
    ]

    /// The league the Teams picker browses by default. A domestic league (the
    /// cups, which lead the list, have no fixed squad to browse).
    static let defaultTeamLeagueID = "4328" // Premier League

    /// Looks up a league by its TheSportsDB id.
    static func league(id: String) -> SportLeague? {
        leagues.first { $0.id == id }
    }
}
