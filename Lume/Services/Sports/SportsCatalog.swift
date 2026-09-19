//
//  SportsCatalog.swift
//  Lume
//
//  The curated, offline list of leagues the Sports Hub can follow, so the browse
//  picker and the per-region default follows work before (or without) any network
//  call. Slugs and sport keys are ESPN's; display names are shown verbatim and are
//  not localised. The table lives in `SportsCatalog+Leagues.swift`; this file is
//  the lookups, the browse order and the per-region defaults. Static,
//  `nonisolated` data only.
//

import Foundation

nonisolated enum SportsCatalog {
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

    // MARK: - Browse order

    /// Regions in the table's order of first appearance — the curated browse
    /// order, so the pickers never keep a second ordering.
    static let regionsInOrder: [SportsRegion] = {
        var seen: Set<SportsRegion> = []
        return leagues.compactMap { seen.insert($0.region).inserted ? $0.region : nil }
    }()

    /// The browse order for a viewer in `region`: the sections closest to home
    /// (a German viewer's Bundesliga block, a US viewer's four big leagues) are
    /// lifted to the top, the rest keep the curated order.
    static func browseRegions(for region: Locale.Region?) -> [SportsRegion] {
        guard let code = region?.identifier.uppercased(), let lifted = homeSections[code] else {
            return regionsInOrder
        }
        return lifted + regionsInOrder.filter { !lifted.contains($0) }
    }

    private static let homeSections: [String: [SportsRegion]] = {
        var map: [String: [SportsRegion]] = [
            "US": [.americanFootball, .basketball, .baseball, .iceHockey, .americas],
            "CA": [.iceHockey, .americas, .americanFootball, .basketball],
            "DE": [.germany], "AT": [.germany, .europe], "CH": [.germany, .europe],
            "GB": [.ukAndIreland], "IE": [.ukAndIreland],
            "ES": [.spain], "IT": [.italy], "FR": [.france], "NL": [.netherlands], "PT": [.portugal],
            "AU": [.australianFootball, .rugby, .restOfWorld, .basketball],
            "NZ": [.rugby, .restOfWorld],
            "ZA": [.rugby, .restOfWorld]
        ]
        for code in ["BE", "TR", "GR", "DK", "NO", "SE", "RU", "PL", "CZ", "HU", "RO", "UA", "HR", "RS", "FI", "BG", "SK"] {
            map[code] = [.europe]
        }
        for code in ["MX", "BR", "AR", "CL", "CO", "PE", "UY", "PY", "EC", "BO", "VE"] {
            map[code] = [.americas]
        }
        for code in ["JP", "CN", "KR", "SA", "IN", "AE", "QA", "SG", "TH", "MY", "ID", "HK", "TW"] {
            map[code] = [.restOfWorld]
        }
        return map
    }()

    // MARK: - Per-region default follows

    /// The small, ordered set of leagues a fresh profile follows, chosen from the
    /// device region. These are ordinary follows the user can remove; written once
    /// per profile by the caller. Falls back to a global default for an unknown or
    /// unlisted region.
    static func regionPreFollows(for region: Locale.Region?) -> [String] {
        guard let code = region?.identifier.uppercased(), let follows = preFollowsByRegion[code] else {
            return globalPreFollows
        }
        return follows
    }

    private static let globalPreFollows = [soccerID("uefa.champions"), soccerID("eng.1")]

    private static func soccerID(_ slug: String) -> String {
        SportsLeague.makeID(sport: "soccer", slug: slug)
    }

    /// ISO region → the league ids it starts with. A domestic top flight plus the
    /// continent's club cup; the four big leagues in the US; football codes in
    /// Australia and the rugby nations.
    private static let preFollowsByRegion: [String: [String]] = {
        let ucl = soccerID("uefa.champions")
        let epl = soccerID("eng.1")
        let libertadores = soccerID("conmebol.libertadores")
        let nhl = SportsLeague.makeID(sport: "hockey", slug: "nhl")
        let nba = SportsLeague.makeID(sport: "basketball", slug: "nba")

        var map: [String: [String]] = [
            "DE": [soccerID("ger.1"), ucl],
            "AT": [soccerID("ger.1"), soccerID("aut.1"), ucl],
            "CH": [soccerID("ger.1"), ucl],
            "GB": [epl, ucl], "IE": [epl, ucl], "KR": [ucl, epl],
            "US": [
                SportsLeague.makeID(sport: "football", slug: "nfl"), nba,
                SportsLeague.makeID(sport: "baseball", slug: "mlb"), nhl
            ],
            "CA": [nhl, nba],
            "AU": [
                SportsLeague.makeID(sport: "australian-football", slug: "afl"),
                SportsLeague.makeID(sport: "rugby-league", slug: "3"),
                soccerID("aus.1")
            ],
            "NZ": [SportsLeague.makeID(sport: "rugby", slug: "242041"), SportsLeague.makeID(sport: "rugby", slug: "244293")],
            "ZA": [soccerID("rsa.1"), SportsLeague.makeID(sport: "rugby", slug: "270557")]
        ]
        // A domestic top flight followed by the Champions League.
        let europeanTopFlights = [
            "ES": "esp.1", "IT": "ita.1", "FR": "fra.1", "NL": "ned.1", "PT": "por.1", "BE": "bel.1", "TR": "tur.1",
            "GR": "gre.1", "DK": "den.1", "NO": "nor.1", "SE": "swe.1", "RU": "rus.1", "MX": "mex.1", "SA": "ksa.1",
            "JP": "jpn.1", "CN": "chn.1"
        ]
        for (code, slug) in europeanTopFlights {
            map[code] = [soccerID(slug), ucl]
        }
        // A domestic top flight followed by the Libertadores.
        let southAmericanTopFlights = [
            "BR": "bra.1", "AR": "arg.1", "CL": "chi.1", "CO": "col.1", "PE": "per.1", "UY": "uru.1", "PY": "par.1",
            "EC": "ecu.1", "BO": "bol.1", "VE": "ven.1"
        ]
        for (code, slug) in southAmericanTopFlights {
            map[code] = [soccerID(slug), libertadores]
        }
        return map
    }()
}
