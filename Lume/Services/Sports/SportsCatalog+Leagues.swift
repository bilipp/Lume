//
//  SportsCatalog+Leagues.swift
//  Lume
//
//  The curated league table itself. Every slug was probed against ESPN's site
//  API (scoreboard, standings, teams) on 2026-09-20; slugs ESPN lists but no
//  longer feeds (Swiss Super League, Cypriot First Division, the Indian, Thai,
//  Malaysian and Indonesian top flights, CFL, Bellator, EuroLeague …) are left
//  out on purpose, as are sports the fixture model can't show — golf, tennis and
//  cricket have no two-sided scoreboard. Names and abbreviations are ours, not
//  the response's, so a card reads "NRL", not "Rugby League". Rugby slugs are
//  ESPN's numeric competition ids.
//

import Foundation

nonisolated extension SportsCatalog {
    /// The full curated league table, in browse order (grouped by `region`).
    static let leagues: [SportsLeague] = germany + ukAndIreland + spain + italy + france + netherlands + portugal
        + europe + clubCompetitions + nationalTeams + womensFootball + americas + restOfWorld
        + americanFootball + basketball + iceHockey + baseball + rugby + australianFootball + lacrosse
        + motorsport + combat

    private static func soccer(_ slug: String, _ name: String, _ abbreviation: String, _ region: SportsRegion) -> SportsLeague {
        SportsLeague(sport: "soccer", slug: slug, name: name, abbreviation: abbreviation, region: region)
    }

    private static let germany: [SportsLeague] = [
        soccer("ger.1", "Bundesliga", "BL", .germany),
        soccer("ger.2", "2. Bundesliga", "2. BL", .germany),
        soccer("ger.dfb_pokal", "DFB-Pokal", "DFB", .germany),
        soccer("ger.super_cup", "DFL-Supercup", "SUPERCUP", .germany),
        soccer("ger.playoff.relegation", "Bundesliga Relegation", "RELEGATION", .germany)
    ]

    private static let ukAndIreland: [SportsLeague] = [
        soccer("eng.1", "Premier League", "EPL", .ukAndIreland),
        soccer("eng.2", "EFL Championship", "EFL CH", .ukAndIreland),
        soccer("eng.3", "EFL League One", "EFL L1", .ukAndIreland),
        soccer("eng.4", "EFL League Two", "EFL L2", .ukAndIreland),
        soccer("eng.5", "National League", "NAT LGE", .ukAndIreland),
        soccer("eng.fa", "FA Cup", "FA CUP", .ukAndIreland),
        soccer("eng.league_cup", "Carabao Cup", "EFL CUP", .ukAndIreland),
        soccer("eng.trophy", "EFL Trophy", "EFL TR", .ukAndIreland),
        soccer("eng.charity", "Community Shield", "SHIELD", .ukAndIreland),
        soccer("sco.1", "Scottish Premiership", "SPFL", .ukAndIreland),
        soccer("sco.2", "Scottish Championship", "SPFL CH", .ukAndIreland),
        soccer("sco.tennents", "Scottish Cup", "SCO CUP", .ukAndIreland),
        soccer("sco.cis", "Scottish League Cup", "SLC", .ukAndIreland)
    ]

    private static let spain: [SportsLeague] = [
        soccer("esp.1", "LaLiga", "LALIGA", .spain),
        soccer("esp.2", "LaLiga 2", "LALIGA 2", .spain),
        soccer("esp.copa_del_rey", "Copa del Rey", "CDR", .spain),
        soccer("esp.super_cup", "Supercopa de España", "SUPERCOPA", .spain)
    ]

    private static let italy: [SportsLeague] = [
        soccer("ita.1", "Serie A", "SERIE A", .italy),
        soccer("ita.2", "Serie B", "SERIE B", .italy),
        soccer("ita.coppa_italia", "Coppa Italia", "COPPA", .italy),
        soccer("ita.super_cup", "Supercoppa Italiana", "SUPERCOPPA", .italy)
    ]

    private static let france: [SportsLeague] = [
        soccer("fra.1", "Ligue 1", "L1", .france),
        soccer("fra.2", "Ligue 2", "L2", .france),
        soccer("fra.coupe_de_france", "Coupe de France", "CDF", .france),
        soccer("fra.super_cup", "Trophée des Champions", "TDC", .france)
    ]

    private static let netherlands: [SportsLeague] = [
        soccer("ned.1", "Eredivisie", "ERE", .netherlands),
        soccer("ned.2", "Keuken Kampioen Divisie", "KKD", .netherlands),
        soccer("ned.cup", "KNVB Beker", "KNVB", .netherlands),
        soccer("ned.supercup", "Johan Cruijff Schaal", "JC SCHAAL", .netherlands)
    ]

    private static let portugal: [SportsLeague] = [
        soccer("por.1", "Primeira Liga", "LIGA", .portugal),
        soccer("por.taca.portugal", "Taça de Portugal", "TAÇA", .portugal)
    ]

    private static let europe: [SportsLeague] = [
        soccer("bel.1", "Belgian Pro League", "JPL", .europe),
        soccer("aut.1", "Austrian Bundesliga", "AUT BL", .europe),
        soccer("tur.1", "Süper Lig", "SÜPER LIG", .europe),
        soccer("gre.1", "Super League Greece", "GRE SL", .europe),
        soccer("den.1", "Danish Superliga", "SUPERLIGA", .europe),
        soccer("nor.1", "Eliteserien", "ELITE", .europe),
        soccer("swe.1", "Allsvenskan", "ALLSV", .europe),
        soccer("rus.1", "Russian Premier League", "RPL", .europe)
    ]

    private static let clubCompetitions: [SportsLeague] = [
        soccer("uefa.champions", "UEFA Champions League", "UCL", .clubCompetitions),
        soccer("uefa.europa", "UEFA Europa League", "UEL", .clubCompetitions),
        soccer("uefa.europa.conf", "UEFA Conference League", "UECL", .clubCompetitions),
        soccer("uefa.super_cup", "UEFA Super Cup", "USC", .clubCompetitions),
        soccer("fifa.cwc", "FIFA Club World Cup", "CWC", .clubCompetitions),
        soccer("conmebol.libertadores", "Copa Libertadores", "LIB", .clubCompetitions),
        soccer("conmebol.sudamericana", "Copa Sudamericana", "SUDA", .clubCompetitions),
        soccer("conmebol.recopa", "Recopa Sudamericana", "RECOPA", .clubCompetitions),
        soccer("concacaf.champions", "Concacaf Champions Cup", "CCC", .clubCompetitions),
        soccer("concacaf.leagues.cup", "Leagues Cup", "LC", .clubCompetitions),
        soccer("caf.champions", "CAF Champions League", "CAF CL", .clubCompetitions),
        soccer("caf.confed", "CAF Confederation Cup", "CAF CC", .clubCompetitions),
        soccer("afc.champions", "AFC Champions League Elite", "ACLE", .clubCompetitions),
        soccer("afc.cup", "AFC Champions League Two", "ACL2", .clubCompetitions),
        soccer("club.friendly", "Club Friendlies", "FRIENDLY", .clubCompetitions)
    ]

    private static let nationalTeams: [SportsLeague] = [
        soccer("fifa.world", "FIFA World Cup", "WC", .international),
        soccer("fifa.worldq.uefa", "World Cup Qualifying – UEFA", "WCQ UEFA", .international),
        soccer("fifa.worldq.conmebol", "World Cup Qualifying – CONMEBOL", "WCQ CONMEBOL", .international),
        soccer("fifa.worldq.concacaf", "World Cup Qualifying – Concacaf", "WCQ CONCACAF", .international),
        soccer("fifa.worldq.caf", "World Cup Qualifying – CAF", "WCQ CAF", .international),
        soccer("fifa.worldq.afc", "World Cup Qualifying – AFC", "WCQ AFC", .international),
        soccer("uefa.euro", "UEFA European Championship", "EURO", .international),
        soccer("uefa.euroq", "EURO Qualifying", "EURO Q", .international),
        soccer("uefa.nations", "UEFA Nations League", "UNL", .international),
        soccer("conmebol.america", "Copa América", "COPA AM", .international),
        soccer("concacaf.gold", "Concacaf Gold Cup", "GOLD CUP", .international),
        soccer("concacaf.nations.league", "Concacaf Nations League", "CNL", .international),
        soccer("caf.nations", "Africa Cup of Nations", "AFCON", .international),
        soccer("caf.nations_qual", "AFCON Qualifying", "AFCON Q", .international),
        soccer("afc.asian.cup", "AFC Asian Cup", "ASIAN CUP", .international),
        soccer("fifa.friendly", "International Friendlies", "FRIENDLY", .international)
    ]

    private static let womensFootball: [SportsLeague] = [
        soccer("fifa.wwc", "FIFA Women's World Cup", "WWC", .womensFootball),
        soccer("uefa.weuro", "UEFA Women's EURO", "WEURO", .womensFootball),
        soccer("uefa.w.nations", "UEFA Women's Nations League", "WNL", .womensFootball),
        soccer("uefa.wchampions", "UEFA Women's Champions League", "UWCL", .womensFootball),
        soccer("eng.w.1", "Women's Super League", "WSL", .womensFootball),
        soccer("eng.w.fa", "Women's FA Cup", "WFA CUP", .womensFootball),
        soccer("esp.w.1", "Liga F", "LIGA F", .womensFootball),
        soccer("esp.copa_de_la_reina", "Copa de la Reina", "COPA REINA", .womensFootball),
        soccer("fra.w.1", "Première Ligue", "D1 F", .womensFootball),
        soccer("ned.w.1", "Vrouwen Eredivisie", "VROUWEN ERE", .womensFootball),
        soccer("usa.nwsl", "NWSL", "NWSL", .womensFootball),
        soccer("usa.w.usl.1", "USL Super League", "USL SL", .womensFootball),
        soccer("can.w.nsl", "Northern Super League", "NSL", .womensFootball),
        soccer("aus.w.1", "A-League Women", "ALW", .womensFootball),
        soccer("fifa.friendly.w", "Women's International Friendlies", "W FRIENDLY", .womensFootball)
    ]

    private static let americas: [SportsLeague] = [
        soccer("usa.1", "MLS", "MLS", .americas),
        soccer("usa.open", "U.S. Open Cup", "USOC", .americas),
        soccer("usa.usl.1", "USL Championship", "USLC", .americas),
        soccer("usa.usl.l1", "USL League One", "USL1", .americas),
        soccer("mex.1", "Liga MX", "LIGA MX", .americas),
        soccer("mex.2", "Liga de Expansión MX", "LIGA EXP", .americas),
        soccer("bra.1", "Brasileirão Série A", "BRA A", .americas),
        soccer("bra.2", "Brasileirão Série B", "BRA B", .americas),
        soccer("bra.copa_do_brazil", "Copa do Brasil", "CDB", .americas),
        soccer("arg.1", "Liga Profesional Argentina", "LPF", .americas),
        soccer("arg.copa", "Copa Argentina", "COPA ARG", .americas),
        soccer("chi.1", "Primera División de Chile", "CHI", .americas),
        soccer("col.1", "Primera A Colombia", "COL", .americas),
        soccer("per.1", "Liga 1 Perú", "PER", .americas),
        soccer("uru.1", "Liga AUF Uruguaya", "URU", .americas),
        soccer("par.1", "Primera División de Paraguay", "PAR", .americas),
        soccer("ecu.1", "LigaPro Ecuador", "ECU", .americas),
        soccer("bol.1", "Liga Profesional Boliviana", "BOL", .americas),
        soccer("ven.1", "Liga FUTVE", "VEN", .americas)
    ]

    private static let restOfWorld: [SportsLeague] = [
        soccer("ksa.1", "Saudi Pro League", "SPL", .restOfWorld),
        soccer("ksa.kings.cup", "Saudi King's Cup", "KING'S CUP", .restOfWorld),
        soccer("jpn.1", "J1 League", "J1", .restOfWorld),
        soccer("chn.1", "Chinese Super League", "CSL", .restOfWorld),
        soccer("aus.1", "A-League Men", "ALM", .restOfWorld),
        soccer("rsa.1", "South African Premiership", "PSL", .restOfWorld)
    ]

    private static let americanFootball: [SportsLeague] = [
        SportsLeague(sport: "football", slug: "nfl", name: "NFL", abbreviation: "NFL", region: .americanFootball),
        SportsLeague(sport: "football", slug: "college-football", name: "College Football", abbreviation: "NCAAF", region: .americanFootball),
        SportsLeague(sport: "football", slug: "ufl", name: "UFL", abbreviation: "UFL", region: .americanFootball)
    ]

    private static let basketball: [SportsLeague] = [
        SportsLeague(sport: "basketball", slug: "nba", name: "NBA", abbreviation: "NBA", region: .basketball),
        SportsLeague(sport: "basketball", slug: "wnba", name: "WNBA", abbreviation: "WNBA", region: .basketball),
        SportsLeague(sport: "basketball", slug: "mens-college-basketball", name: "Men's College Basketball", abbreviation: "NCAAM", region: .basketball),
        SportsLeague(sport: "basketball", slug: "womens-college-basketball", name: "Women's College Basketball", abbreviation: "NCAAW", region: .basketball),
        SportsLeague(sport: "basketball", slug: "nba-development", name: "NBA G League", abbreviation: "G LEAGUE", region: .basketball),
        SportsLeague(sport: "basketball", slug: "nbl", name: "NBL", abbreviation: "NBL", region: .basketball),
        SportsLeague(sport: "basketball", slug: "fiba", name: "FIBA World Cup", abbreviation: "FIBA WC", region: .basketball)
    ]

    private static let iceHockey: [SportsLeague] = [
        SportsLeague(sport: "hockey", slug: "nhl", name: "NHL", abbreviation: "NHL", region: .iceHockey),
        SportsLeague(sport: "hockey", slug: "mens-college-hockey", name: "Men's College Hockey", abbreviation: "NCAAH", region: .iceHockey),
        SportsLeague(sport: "hockey", slug: "womens-college-hockey", name: "Women's College Hockey", abbreviation: "NCAAWH", region: .iceHockey)
    ]

    private static let baseball: [SportsLeague] = [
        SportsLeague(sport: "baseball", slug: "mlb", name: "MLB", abbreviation: "MLB", region: .baseball),
        SportsLeague(sport: "baseball", slug: "college-baseball", name: "College Baseball", abbreviation: "NCAA BSB", region: .baseball),
        SportsLeague(sport: "baseball", slug: "college-softball", name: "College Softball", abbreviation: "NCAA SB", region: .baseball),
        SportsLeague(sport: "baseball", slug: "world-baseball-classic", name: "World Baseball Classic", abbreviation: "WBC", region: .baseball)
    ]

    private static let rugby: [SportsLeague] = [
        SportsLeague(sport: "rugby", slug: "267979", name: "Gallagher Premiership", abbreviation: "PREM", region: .rugby),
        SportsLeague(sport: "rugby", slug: "270559", name: "Top 14", abbreviation: "TOP 14", region: .rugby),
        SportsLeague(sport: "rugby", slug: "270557", name: "United Rugby Championship", abbreviation: "URC", region: .rugby),
        SportsLeague(sport: "rugby", slug: "242041", name: "Super Rugby Pacific", abbreviation: "SUPER RUGBY", region: .rugby),
        SportsLeague(sport: "rugby", slug: "244293", name: "The Rugby Championship", abbreviation: "TRC", region: .rugby),
        SportsLeague(sport: "rugby", slug: "289234", name: "International Test Matches", abbreviation: "TEST", region: .rugby),
        SportsLeague(sport: "rugby", slug: "289262", name: "Major League Rugby", abbreviation: "MLR", region: .rugby),
        SportsLeague(sport: "rugby-league", slug: "3", name: "NRL", abbreviation: "NRL", region: .rugby)
    ]

    private static let australianFootball: [SportsLeague] = [
        SportsLeague(sport: "australian-football", slug: "afl", name: "AFL", abbreviation: "AFL", region: .australianFootball)
    ]

    private static let lacrosse: [SportsLeague] = [
        SportsLeague(sport: "lacrosse", slug: "pll", name: "Premier Lacrosse League", abbreviation: "PLL", region: .lacrosse),
        SportsLeague(sport: "lacrosse", slug: "nll", name: "National Lacrosse League", abbreviation: "NLL", region: .lacrosse)
    ]

    private static let motorsport: [SportsLeague] = [
        SportsLeague(sport: "racing", slug: "f1", name: "Formula 1", abbreviation: "F1", region: .motorsport),
        SportsLeague(sport: "racing", slug: "irl", name: "IndyCar Series", abbreviation: "INDYCAR", region: .motorsport),
        SportsLeague(sport: "racing", slug: "nascar-premier", name: "NASCAR Cup Series", abbreviation: "NASCAR", region: .motorsport),
        SportsLeague(sport: "racing", slug: "nascar-secondary", name: "NASCAR O'Reilly Auto Parts Series", abbreviation: "NASCAR 2", region: .motorsport),
        SportsLeague(sport: "racing", slug: "nascar-truck", name: "NASCAR Truck Series", abbreviation: "TRUCKS", region: .motorsport)
    ]

    private static let combat: [SportsLeague] = [
        SportsLeague(sport: "mma", slug: "ufc", name: "UFC", abbreviation: "UFC", region: .combat),
        SportsLeague(sport: "mma", slug: "pfl", name: "PFL", abbreviation: "PFL", region: .combat)
    ]
}
