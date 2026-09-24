//
//  SportsChannelResolver+Racing.swift
//  Lume
//
//  Channel resolution for race sessions, which have no two teams to match on.
//  A programme carries a session when it names the series ("F1", "Formel 1")
//  and either names this session ("1. Freies Training", "Qualifying") or names
//  no session at all ("Formel 1 - Grand Prix von Aserbaidschan") — the kickoff
//  window then decides. A programme naming a *different* session or another
//  series (F2, Supercup) on the same weekend is never offered.
//

import Foundation

nonisolated extension SportsChannelResolver {
    /// The channels carrying one race session (or an unexpanded race weekend).
    static func resolveRace(
        fixture: SportsFixture,
        channels: [Channel],
        guide: [String: [NormalizedCandidate]],
        pickIndex: [String: String]
    ) -> [ResolvedChannel] {
        let series = SportsRaceMatcher.seriesPhrases(leagueId: fixture.leagueId)
        guard !series.isEmpty else { return [] }
        let kind = fixture.sessionKind ?? (fixture.sessions.count == 1 ? fixture.sessions.first?.kind : nil)

        var resolved: [ResolvedChannel] = []
        for channel in channels {
            let channelNamesSeries = SportsRaceMatcher.containsAny(series, in: channel.nameHaystack)
            let listings = channel.summary.epgChannelId.flatMap { guide[$0] } ?? []
            let epg = bestRaceHit(
                in: listings,
                series: series,
                kind: kind,
                channelNamesSeries: channelNamesSeries,
                kickoff: fixture.startDate
            )
            let channelKey = SportsChannelPicks.channelKey(
                epgChannelId: channel.summary.epgChannelId, name: channel.summary.name
            )
            let isPick = pickIndex[
                SportsChannelPicks.compositeKey(competitionKey: fixture.leagueId, channelKey: channelKey)
            ] != nil
            // A series-named channel ("Sky Sports F1") with no guide entry at the
            // session's start is a fallback; one airing something else is not.
            let airingAtStart = listings.contains { $0.start <= fixture.startDate && $0.end > fixture.startDate }
            let nameFallback = channelNamesSeries && !airingAtStart

            let source: ResolvedChannelSource
            let score: Int
            if isPick {
                source = .userPick
                score = pickScoreBase + (epg?.score ?? 0)
            } else if let epg {
                source = epg.source
                score = epg.score
            } else if nameFallback {
                source = .channelName
                score = nameMatchScore
            } else {
                continue
            }
            resolved.append(ResolvedChannel(
                stream: channel.summary,
                playlistID: channel.playlistID,
                matchedTitle: epg?.title,
                matchedStart: epg?.start,
                score: score,
                source: source,
                isConfident: false
            ))
        }
        return resolved
    }

    private struct RaceHit {
        let score: Int
        let source: ResolvedChannelSource
        let title: String
        let start: Date
    }

    /// The best programme for a race session inside the kickoff window.
    ///
    /// Tiers: series and this session named together in one headline field (or
    /// the session named on a series-named channel) is the fixture line itself;
    /// the series in the headline with the session elsewhere or unnamed is the
    /// next tier; the series only in the description is the weakest.
    private static func bestRaceHit(
        in candidates: [NormalizedCandidate],
        series: [String],
        kind: SportsSessionKind?,
        channelNamesSeries: Bool,
        kickoff: Date
    ) -> RaceHit? {
        let windowStart = kickoff.addingTimeInterval(-SportsMatcher.leadTime)
        let windowEnd = kickoff.addingTimeInterval(SportsMatcher.lateStart)

        var best: RaceHit?
        for candidate in candidates {
            guard candidate.start >= windowStart, candidate.start <= windowEnd else { continue }
            let title = candidate.normalizedTitle
            let subtitle = candidate.normalizedSubtitle
            let headline = title + subtitle
            guard !SportsRaceMatcher.namesOtherSeries(headline) else { continue }

            let titleSessions = SportsRaceMatcher.sessions(in: title, ignoring: series)
            let subtitleSessions = SportsRaceMatcher.sessions(in: subtitle, ignoring: series)
            let named = titleSessions.union(subtitleSessions)
            // Naming another session of the weekend rules the programme out.
            if let kind, !named.isEmpty, !named.contains(kind) { continue }
            let namesThis = kind.map { named.contains($0) } ?? false

            let seriesInTitle = SportsRaceMatcher.containsAny(series, in: title)
            let seriesInSub = SportsRaceMatcher.containsAny(series, in: subtitle)
            let seriesInBody = SportsRaceMatcher.containsAny(series, in: candidate.normalizedDescription)

            let source: ResolvedChannelSource
            if let kind, namesThis,
               (seriesInTitle && titleSessions.contains(kind))
               || (seriesInSub && subtitleSessions.contains(kind))
               || channelNamesSeries
            {
                source = .epgTitleSubtitle
            } else if seriesInTitle || seriesInSub {
                source = .epgSingleField
            } else if seriesInBody {
                source = .epgDescription
            } else {
                continue
            }

            let score = (seriesInSub ? subtitleWeight : 0) + (seriesInTitle ? titleWeight : 0)
                + (seriesInBody ? descriptionWeight : 0) + (namesThis ? SportsRaceMatcher.sessionWeight : 0)
            let hit = RaceHit(score: score, source: source, title: candidate.title, start: candidate.start)
            if isBetterRaceHit(hit, than: best, kickoff: kickoff) { best = hit }
        }
        return best
    }

    private static func isBetterRaceHit(_ lhs: RaceHit, than rhs: RaceHit?, kickoff: Date) -> Bool {
        guard let rhs else { return true }
        if lhs.source.rank != rhs.source.rank { return lhs.source.rank < rhs.source.rank }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return abs(lhs.start.timeIntervalSince(kickoff)) < abs(rhs.start.timeIntervalSince(kickoff))
    }
}

/// Series and session vocabulary for race EPG titles, across the app's
/// languages. Every phrase is in `SportsMatcher.normalize` form (lowercase,
/// accent-free, punctuation as spaces) and matched as whole words.
nonisolated enum SportsRaceMatcher {
    /// A programme naming the session outweighs one where the series alone is
    /// found, so the session broadcast wins over a same-window magazine.
    static let sessionWeight = 3

    /// The phrases naming a racing league's series in a guide, or `[]` for a
    /// league that isn't a racing series.
    static func seriesPhrases(leagueId: String) -> [String] {
        switch leagueId.split(separator: "/").last.map(String.init) ?? "" {
        case "f1": ["f1", "formel 1", "formel1", "formula 1", "formula1", "formula one", "formule 1", "formula uno"]
        case "irl": ["indycar", "indy car", "indy 500", "indianapolis 500"]
        case let slug where slug.hasPrefix("nascar"): ["nascar"]
        default: []
        }
    }

    /// Feeder and support series that share an F1 weekend (and channel) but
    /// aren't the session: "Live F2: Sprint", "Porsche Supercup".
    private static let otherSeries = [
        "f2", "f3", "formel 2", "formel 3", "formula 2", "formula 3", "formule 2", "formule 3",
        "f1 academy", "supercup"
    ]

    static func namesOtherSeries(_ haystack: String) -> Bool {
        containsAny(otherSeries, in: haystack)
    }

    static func containsAny(_ phrases: [String], in haystack: String) -> Bool {
        phrases.contains { haystack.contains(" \($0) ") }
    }

    /// The sessions a (normalized) text names. An unnumbered practice
    /// ("Freies Training") stands for all three practices; a sprint title
    /// never also counts as the race or the qualifying. The `series` phrases are
    /// cut first, so the "1" of "Formel 1 Training" doesn't read as practice 1.
    static func sessions(in text: String, ignoring series: [String] = []) -> Set<SportsSessionKind> {
        var haystack = text
        for phrase in series {
            while haystack.contains(" \(phrase) ") {
                haystack = haystack.replacingOccurrences(of: " \(phrase) ", with: " ")
            }
        }
        var result: Set<SportsSessionKind> = []
        for (number, kind) in [(1, SportsSessionKind.fp1), (2, .fp2), (3, .fp3)]
            where containsAny(practicePhrases(number), in: haystack)
        {
            result.insert(kind)
        }
        if result.isEmpty, containsAny(practiceWords, in: haystack) {
            result = [.fp1, .fp2, .fp3]
        }
        if containsAny(sprintQualifyingPhrases, in: haystack) {
            result.insert(.sprintQualifying)
        } else if containsAny(sprintPhrases, in: haystack) {
            result.insert(.sprint)
        } else {
            if containsAny(qualifyingPhrases, in: haystack) { result.insert(.qualifying) }
            if containsAny(racePhrases, in: haystack) { result.insert(.race) }
        }
        return result
    }

    private static let practiceWords = [
        "free practice", "practice", "freies training", "training", "essais libres", "libres",
        "prove libere", "entrenamientos libres", "practica libre", "practicas libres", "treino livre",
        "treinos livres", "vrije training"
    ]

    /// "Free Practice 1", "1. Freies Training", "FP1", "Practice One", "EL1"…
    private static func practicePhrases(_ number: Int) -> [String] {
        let spelled = ["one", "two", "three"][number - 1]
        let ordinal = ["first", "second", "third"][number - 1]
        return practiceWords.flatMap { ["\($0) \(number)", "\(number) \($0)"] }
            + ["fp\(number)", "el\(number)", "pl\(number)", "tl\(number)", "practice \(spelled)", "\(ordinal) practice"]
    }

    private static let sprintQualifyingPhrases = [
        "sprint qualifying", "sprint quali", "sprint qualifikation", "sprintqualifying", "sprint shootout",
        "qualifiche sprint", "qualifs sprint", "qualifications sprint", "clasificacion sprint",
        "classificacao sprint", "sprint kwalificatie"
    ]

    private static let sprintPhrases = ["sprint", "sprintrennen", "sprint race", "gara sprint", "course sprint"]

    private static let qualifyingPhrases = [
        "qualifying", "qualifikation", "quali", "qualy", "qualifiche", "qualification", "qualifications",
        "qualifs", "clasificacion", "classificacao", "kwalificatie"
    ]

    private static let racePhrases = ["race", "rennen", "das rennen", "gara", "course", "carrera", "corrida", "wedstrijd"]
}
