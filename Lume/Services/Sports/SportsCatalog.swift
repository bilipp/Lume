//
//  SportsCatalog.swift
//  Lume
//
//  The curated, offline list of leagues the Sports Hub can follow, so the browse
//  picker and the per-region default follows work before (or without) any network
//  call. Slugs and sport keys are ESPN's; display names are shown verbatim and are
//  not localised. Static, `nonisolated` data only.
//

import Foundation

nonisolated enum SportsCatalog {
    /// The full curated league table, in browse order (grouped by `region`).
    static let leagues: [SportsLeague] = [
        // Germany
        SportsLeague(sport: "soccer", slug: "ger.1", name: "Bundesliga", abbreviation: "BUND", region: .germany),
        SportsLeague(sport: "soccer", slug: "ger.dfb_pokal", name: "DFB-Pokal", abbreviation: "DFB", region: .germany),
        // UK & Ireland
        SportsLeague(sport: "soccer", slug: "eng.1", name: "Premier League", abbreviation: "EPL", region: .ukAndIreland),
        SportsLeague(sport: "soccer", slug: "eng.fa", name: "FA Cup", abbreviation: "FA", region: .ukAndIreland),
        SportsLeague(sport: "soccer", slug: "eng.league_cup", name: "EFL Cup", abbreviation: "EFL", region: .ukAndIreland),
        SportsLeague(sport: "soccer", slug: "sco.1", name: "Scottish Premiership", abbreviation: "SPFL", region: .ukAndIreland),
        // Spain
        SportsLeague(sport: "soccer", slug: "esp.1", name: "LaLiga", abbreviation: "LALIGA", region: .spain),
        SportsLeague(sport: "soccer", slug: "esp.copa_del_rey", name: "Copa del Rey", abbreviation: "CDR", region: .spain),
        // Italy
        SportsLeague(sport: "soccer", slug: "ita.1", name: "Serie A", abbreviation: "SERIEA", region: .italy),
        // France
        SportsLeague(sport: "soccer", slug: "fra.1", name: "Ligue 1", abbreviation: "L1", region: .france),
        // Europe (other domestic leagues)
        SportsLeague(sport: "soccer", slug: "ned.1", name: "Eredivisie", abbreviation: "ERE", region: .europe),
        SportsLeague(sport: "soccer", slug: "por.1", name: "Primeira Liga", abbreviation: "LIGA", region: .europe),
        SportsLeague(sport: "soccer", slug: "tur.1", name: "Süper Lig", abbreviation: "SUPER", region: .europe),
        SportsLeague(sport: "soccer", slug: "bel.1", name: "Belgian Pro League", abbreviation: "JPL", region: .europe),
        SportsLeague(sport: "soccer", slug: "aut.1", name: "Austrian Bundesliga", abbreviation: "ADMIRAL", region: .europe),
        SportsLeague(sport: "soccer", slug: "sui.1", name: "Swiss Super League", abbreviation: "SSL", region: .europe),
        SportsLeague(sport: "soccer", slug: "ksa.1", name: "Saudi Pro League", abbreviation: "SPL", region: .europe),
        // Americas
        SportsLeague(sport: "soccer", slug: "usa.1", name: "MLS", abbreviation: "MLS", region: .americas),
        SportsLeague(sport: "soccer", slug: "mex.1", name: "Liga MX", abbreviation: "LIGAMX", region: .americas),
        SportsLeague(sport: "soccer", slug: "bra.1", name: "Brasileirão", abbreviation: "BRA", region: .americas),
        SportsLeague(sport: "soccer", slug: "arg.1", name: "Liga Profesional", abbreviation: "ARG", region: .americas),
        // US Leagues
        SportsLeague(sport: "football", slug: "nfl", name: "NFL", abbreviation: "NFL", region: .usLeagues),
        SportsLeague(sport: "football", slug: "college-football", name: "College Football", abbreviation: "NCAAF", region: .usLeagues),
        SportsLeague(sport: "basketball", slug: "nba", name: "NBA", abbreviation: "NBA", region: .usLeagues),
        SportsLeague(sport: "basketball", slug: "wnba", name: "WNBA", abbreviation: "WNBA", region: .usLeagues),
        SportsLeague(sport: "basketball", slug: "mens-college-basketball", name: "Men's College Basketball", abbreviation: "NCAAM", region: .usLeagues),
        SportsLeague(sport: "hockey", slug: "nhl", name: "NHL", abbreviation: "NHL", region: .usLeagues),
        SportsLeague(sport: "baseball", slug: "mlb", name: "MLB", abbreviation: "MLB", region: .usLeagues),
        // International (continental & national-team competitions)
        SportsLeague(sport: "soccer", slug: "uefa.champions", name: "UEFA Champions League", abbreviation: "UCL", region: .international),
        SportsLeague(sport: "soccer", slug: "uefa.europa", name: "UEFA Europa League", abbreviation: "UEL", region: .international),
        SportsLeague(sport: "soccer", slug: "uefa.europa.conf", name: "UEFA Conference League", abbreviation: "UECL", region: .international),
        SportsLeague(sport: "soccer", slug: "uefa.nations", name: "UEFA Nations League", abbreviation: "UNL", region: .international),
        SportsLeague(sport: "soccer", slug: "fifa.world", name: "FIFA World Cup", abbreviation: "WC", region: .international),
        SportsLeague(sport: "soccer", slug: "fifa.worldq.uefa", name: "World Cup Qualifying - UEFA", abbreviation: "WCQ", region: .international),
        SportsLeague(sport: "soccer", slug: "conmebol.libertadores", name: "Copa Libertadores", abbreviation: "LIB", region: .international),
        // Motorsport
        SportsLeague(sport: "racing", slug: "f1", name: "Formula 1", abbreviation: "F1", region: .motorsport),
        // Combat
        SportsLeague(sport: "mma", slug: "ufc", name: "UFC", abbreviation: "UFC", region: .combat)
    ]

    /// Fast id lookup into `leagues`.
    private static let leaguesByID: [String: SportsLeague] = Dictionary(
        uniqueKeysWithValues: leagues.map { ($0.id, $0) }
    )

    static func league(id: String) -> SportsLeague? {
        leaguesByID[id]
    }

    static func league(sport: String, slug: String) -> SportsLeague? {
        leaguesByID[SportsLeague.makeID(sport: sport, slug: slug)]
    }

    static func leagues(in region: SportsRegion) -> [SportsLeague] {
        leagues.filter { $0.region == region }
    }

    // MARK: - Per-region default follows

    /// The small, ordered set of leagues a fresh profile follows, chosen from the
    /// device region. These are ordinary follows the user can remove; written once
    /// per profile by the caller. Falls back to a global default for an unknown or
    /// unlisted region.
    static func regionPreFollows(for region: Locale.Region?) -> [String] {
        let ucl = SportsLeague.makeID(sport: "soccer", slug: "uefa.champions")
        let epl = SportsLeague.makeID(sport: "soccer", slug: "eng.1")
        func soccer(_ slug: String) -> String {
            SportsLeague.makeID(sport: "soccer", slug: slug)
        }
        let globalDefault = [ucl, epl]

        guard let code = region?.identifier.uppercased() else { return globalDefault }

        let unitedStates = [
            SportsLeague.makeID(sport: "football", slug: "nfl"),
            SportsLeague.makeID(sport: "basketball", slug: "nba"),
            SportsLeague.makeID(sport: "baseball", slug: "mlb"),
            SportsLeague.makeID(sport: "hockey", slug: "nhl")
        ]
        let byRegion: [String: [String]] = [
            "DE": [soccer("ger.1"), ucl], "AT": [soccer("ger.1"), ucl], "CH": [soccer("ger.1"), ucl],
            "GB": [epl, ucl], "IE": [epl, ucl],
            "US": unitedStates,
            "ES": [soccer("esp.1"), ucl],
            "IT": [soccer("ita.1"), ucl],
            "FR": [soccer("fra.1"), ucl],
            "PT": [soccer("por.1"), ucl],
            "BR": [soccer("bra.1"), ucl],
            "JP": [ucl, epl], "KR": [ucl, epl], "CN": [ucl, epl]
        ]
        return byRegion[code] ?? globalDefault
    }
}
