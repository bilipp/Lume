//
//  SportsReplayLibrary.swift
//  Lume
//
//  A recording or a library file becomes a replay only with one unambiguous
//  fixture. Callers apply visibility before handing either to this helper.
//  Derived values stay outside SwiftData and share the live guide's team matcher.
//

import Foundation
import SwiftData

nonisolated struct SportsReplayGame: Identifiable, Hashable {
    let fixture: SportsFixture
    let recordings: [ServerRecording]
    var library: [SportsLibraryReplay] = []

    var id: String {
        fixture.replayKey
    }

    var addedAt: Date {
        recordings.map(\.createdAt).max() ?? fixture.startDate
    }

    /// Everything that plays this game, recordings first.
    var versions: [SportsReplayVersion] {
        recordings.map(SportsReplayVersion.recording) + library.map(SportsReplayVersion.library)
    }
}

/// A game file in a media library that its source identified as sports
/// (`sportsRef`). A snapshot of the catalog row, which still owns playback,
/// progress and favorites.
nonisolated struct SportsLibraryReplay: Identifiable, Hashable {
    /// Catalog id of the `Episode` or `Movie`.
    let id: String
    let isEpisode: Bool
    let title: String
    /// The playlist that owns it, by its display name: what tells one
    /// version of a game from another when several servers hold it.
    let source: String
    /// The air date the source reports: that calendar day at UTC midnight.
    /// It names a day, not an instant, so it is read back in UTC; local time
    /// would show the day before anywhere west of Greenwich.
    let day: Date?
    /// Where to resume; zero once watched, so a finished game is not continued.
    let progress: Double
    /// The canonical reference of the exact event (`sportarr://ev-…`) when
    /// the source named one; nil for a file known only by its series' league.
    /// Files sharing it are editions of one game, whatever server holds them.
    var event: String?
    /// The series it was filed under, usually the league.
    var league = ""
}

nonisolated extension SportsLibraryReplay {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The air date as the source wrote it.
    var dayLabel: String? {
        day?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    /// The start of the same calendar day in `calendar`, for comparing with
    /// date ranges the viewer chose in their own time zone.
    func day(in calendar: Calendar) -> Date? {
        day.flatMap { calendar.date(from: Self.utc.dateComponents([.year, .month, .day], from: $0)) }
    }
}

extension SportsLibraryReplay {
    /// Playback through the catalog row and the playlist that own the file,
    /// as its own detail page would play it.
    @MainActor func media(in context: ModelContext) -> PlayableMedia? {
        guard let playlist = PlaylistOwner.playlist(forPrefixedID: id, in: context) else { return nil }
        let id = id
        return if isEpisode {
            (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })))?.first
                .flatMap { PlayableMedia.from(episode: $0, playlist: playlist) }
        } else {
            (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })))?.first
                .flatMap { PlayableMedia.from(movie: $0, playlist: playlist) }
        }
    }
}

extension Episode {
    /// A game is not an instalment. While library replays are on, a sports
    /// episode has no next or previous one to advance to.
    func isStandaloneReplay(replaysOn: Bool = UserDefaults.standard.bool(forKey: SportsSyncService.libraryReplaysKey)) -> Bool {
        replaysOn && (sportsRef ?? series?.sportsRef) != nil
    }
}

nonisolated enum SportsReplayVersion: Identifiable, Hashable {
    case recording(ServerRecording)
    case library(SportsLibraryReplay)

    var id: String {
        switch self {
        case let .recording(recording): recording.id.rawValue
        case let .library(file): file.id
        }
    }
}

nonisolated extension SportsFixture {
    /// ESPN event ids are unique per league only.
    var replayKey: String {
        leagueId + ":" + id
    }
}

nonisolated extension ServerRecording {
    /// A recording that holds something to watch.
    var isReplayable: Bool {
        status == .completed || status == .recording
    }
}

/// One matching pass's fixtures, and the team tokens built for them so far.
/// A season's library weighs every file against every fixture near its date.
/// Tokenising a team is the costly step, so each fixture's tokens are built
/// once, and the matcher is asked only about fixtures whose two teams both
/// appear among the programme's own words. The matcher still decides: that
/// test is a condition it applies itself, over text that includes all it reads.
private nonisolated struct FixtureIndex {
    let fixtures: [String: SportsFixture]
    private let aliases: SportsTeamAliases
    private var teamTokens: [String: (home: Set<String>, away: Set<String>)] = [:]

    init(fixtures: [SportsFixture], aliases: SportsTeamAliases) {
        self.fixtures = Dictionary(fixtures.map { ($0.replayKey, $0) }, uniquingKeysWith: { first, _ in first })
        self.aliases = aliases
    }

    private mutating func tokens(_ fixture: SportsFixture) -> (home: Set<String>, away: Set<String>)? {
        if let cached = teamTokens[fixture.replayKey] { return cached }
        guard let home = fixture.home?.team, let away = fixture.away?.team else { return nil }
        let built = (SportsMatcher.tokens(for: home, aliases: aliases), SportsMatcher.tokens(for: away, aliases: aliases))
        teamTokens[fixture.replayKey] = built
        return built
    }

    /// The fixtures whose kickoff falls in the programme's window, and those
    /// among them it names.
    mutating func matching(_ programme: EPGProgramCandidate) -> (candidates: [SportsFixture], named: [SportsFixture]) {
        let candidates = fixtures.values.filter { $0.startDate >= programme.start && $0.startDate < programme.end }
        let text = programme.title + " " + programme.subtitle + " " + programme.listingDescription
        let words = Set(SportsMatcher.normalize(text).split(separator: " ").map(String.init))
        var named: [SportsFixture] = []
        for fixture in candidates {
            guard let teams = tokens(fixture), !teams.home.isDisjoint(with: words), !teams.away.isDisjoint(with: words),
                  SportsMatcher.bestMatch(for: fixture, in: [programme], aliases: aliases, requiresKickoffStart: false) != nil
            else { continue }
            named.append(fixture)
        }
        return (candidates, named)
    }
}

nonisolated enum SportsReplayLibrary {
    /// The original programme can identify a partial captured after kickoff.
    /// It is used only with team evidence, never for the channel-only fallback.
    static func games(
        recordings: [ServerRecording],
        library: [SportsLibraryReplay] = [],
        fixtures: [SportsFixture],
        channels: [String: Set<String>] = [:],
        aliases: SportsTeamAliases = .bundled
    ) -> [SportsReplayGame] {
        var index = FixtureIndex(fixtures: fixtures, aliases: aliases)
        let uniqueFixtures = index.fixtures
        var versions: [String: [ServerRecording]] = [:]
        var files: [String: [SportsLibraryReplay]] = [:]
        // A library file states a calendar day, not a kickoff: a night game
        // can fall on either side of it, so the window spans both.
        for file in library {
            guard let day = file.day else { continue }
            let programme = EPGProgramCandidate(
                channelId: "", title: file.title, listingDescription: "",
                start: day.addingTimeInterval(-12 * 3600), end: day.addingTimeInterval(36 * 3600)
            )
            let named = index.matching(programme).named
            guard named.count == 1, let match = named.first else { continue }
            files[match.replayKey, default: []].append(file)
        }
        joinEditions(of: library, into: &files)
        for recording in recordings where recording.isReplayable {
            let start = recording.programmeStart ?? recording.start
            let end = recording.programmeEnd ?? recording.end
            guard start < end else { continue }
            let programme = EPGProgramCandidate(
                channelId: recording.sourceRef ?? "", title: recording.title,
                listingDescription: recording.programmeDescription ?? "", start: start, end: end
            )
            let (candidates, named) = index.matching(programme)
            let match: SportsFixture?
            if named.count == 1 {
                match = named.first
            } else if named.isEmpty, !namesAnyTeam(recording, leagues: Set(candidates.map(\.leagueId)), in: uniqueFixtures.values, aliases: aliases),
                      let ref = recording.sourceRef.flatMap(RecordingSourceRef.init(rawValue:))
            {
                let fallback = candidates.filter {
                    $0.startDate >= recording.start && $0.startDate < recording.end
                        && channels[$0.replayKey]?.contains(ref.rawValue) == true
                }
                match = fallback.count == 1 ? fallback.first : nil
            } else {
                match = nil
            }
            guard let match else { continue }
            versions[match.replayKey, default: []].append(recording)
        }
        return Set(versions.keys).union(files.keys).compactMap { key in
            guard let fixture = uniqueFixtures[key] else { return nil }
            let recordings = (versions[key] ?? []).sorted { $0.createdAt > $1.createdAt }
            return SportsReplayGame(fixture: fixture, recordings: recordings, library: files[key] ?? [])
        }.sorted { $0.fixture.startDate > $1.fixture.startDate }
    }

    /// Every catalog row a source identified as sports, within the playlists
    /// being browsed: movies and episodes carrying an event, and the episodes
    /// of a series carrying a league.
    @MainActor static func files(in context: ModelContext, scope: CatalogScope, restriction: ContentRestriction = ContentRestriction()) -> [SportsLibraryReplay] {
        func day(_ date: String?) -> Date? {
            date.flatMap { try? Date(String($0.prefix(10)), strategy: .iso8601.year().month().day()) }
        }
        let series = scope.seriesPredicate(), film = scope.moviePredicate(), prefixes = scope.prefixes(for: .series)
        let leagues = (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.sportsRef != nil && series.evaluate($0) }))) ?? []
        let events = ((try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.sportsRef != nil }))) ?? [])
            .filter { episode in prefixes.contains { episode.id.hasPrefix($0) } }
        let movies = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.sportsRef != nil && film.evaluate($0) }))) ?? []
        let episodes = Dictionary((leagues.flatMap(\.episodes) + events).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let playlists = ((try? context.fetch(FetchDescriptor<Playlist>())) ?? []).map { (CatalogScope.prefix($0.id), $0.name) }
        func owner(_ id: String) -> String {
            playlists.first { id.hasPrefix($0.0) }?.1 ?? ""
        }
        return episodes.filter { !restriction.hides(categoryID: $0.series?.categoryId) }.map {
            SportsLibraryReplay(
                id: $0.id, isEpisode: true, title: $0.title, source: owner($0.id), day: day($0.airDate), progress: $0.isWatched ? 0 : $0.watchProgress,
                event: SportarrIdentifier.isEvent($0.sportsRef) ? $0.sportsRef : nil, league: $0.series?.name ?? ""
            )
        } + movies.filter { !restriction.hides(categoryID: $0.categoryId) }.map {
            SportsLibraryReplay(
                id: $0.id, isEpisode: false, title: $0.name, source: owner($0.id), day: day($0.releaseDate),
                progress: $0.isWatched ? 0 : $0.watchProgress, event: $0.sportsRef
            )
        }
    }

    /// Some servers list a series without its episodes until it is opened. A
    /// league whose games were never loaded would have none to show, so its
    /// episodes come through the same per-series loader the series page uses.
    /// Bounded per call; a league left over is picked up by the next one.
    @MainActor static func loadMissingEpisodes(
        in context: ModelContext, scope: CatalogScope, restriction: ContentRestriction = ContentRestriction(), limit: Int = 25
    ) async {
        let scoped = scope.seriesPredicate()
        let leagues = ((try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.sportsRef != nil && scoped.evaluate($0) }))) ?? [])
            .filter { $0.episodes.isEmpty && !restriction.hides(categoryID: $0.categoryId) }
        guard !leagues.isEmpty else { return }
        let manager = ContentSyncManager(modelContainer: context.container)
        for series in leagues.prefix(limit) {
            guard let playlist = PlaylistOwner.playlist(forPrefixedID: series.id, in: context), playlist.supportsPerSeriesEpisodeFetch,
                  let parsed = try? await manager.fetchEpisodes(seriesId: series.seriesId, seriesElementId: series.id, playlist: playlist)
            else { continue }
            series.insertEpisodes(parsed, into: context)
        }
    }

    /// Categories that hold nothing but routed sports items. Their rows would
    /// otherwise stay behind, empty, once the items moved to Replays.
    @MainActor static func routedCategories(for tab: PlaylistTab, in context: ModelContext) -> Set<String> {
        if tab == .movies {
            let sports = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.sportsRef != nil }))) ?? []
            return Set(sports.compactMap(\.categoryId)).filter { id in
                (try? context.fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.categoryId == id && $0.sportsRef == nil }))) == 0
            }
        }
        let leagues = (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.sportsRef != nil && !$0.episodes.isEmpty }))) ?? []
        return Set(leagues.compactMap(\.categoryId)).filter { id in
            let ordinary = FetchDescriptor<Series>(predicate: #Predicate { $0.categoryId == id && ($0.sportsRef == nil || $0.episodes.isEmpty) })
            return (try? context.fetchCount(ordinary)) == 0
        }
    }

    /// The schedule months those files can fall in, given the same day-either-
    /// side window `games` matches with.
    static func months(of files: [SportsLibraryReplay]) -> Set<DateComponents> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let days = files.compactMap(\.day).flatMap { [$0.addingTimeInterval(-12 * 3600), $0.addingTimeInterval(36 * 3600)] }
        return Set(days.map { calendar.dateComponents([.year, .month], from: $0) })
    }

    /// Editions of one event are one game: a condensed file whose title names
    /// no team joins the game its full edition was placed in.
    private static func joinEditions(of library: [SportsLibraryReplay], into files: inout [String: [SportsLibraryReplay]]) {
        var gamesByEvent: [String: Set<String>] = [:]
        for (key, editions) in files {
            for event in editions.compactMap(\.event) {
                gamesByEvent[event, default: []].insert(key)
            }
        }
        let placed = Set(files.values.joined().map(\.id))
        for file in library where !placed.contains(file.id) {
            guard let event = file.event, let keys = gamesByEvent[event], keys.count == 1, let key = keys.first else { continue }
            files[key, default: []].append(file)
        }
    }

    /// Whether the programme names any team of those leagues, not only the
    /// teams kicking off in its window: a rebroadcast of an earlier game on a
    /// league's channel names that game's teams, and is no game of this window.
    private static func namesAnyTeam(
        _ recording: ServerRecording, leagues: Set<String>, in fixtures: some Collection<SportsFixture>, aliases: SportsTeamAliases
    ) -> Bool {
        let haystack = SportsMatcher.normalize(recording.title + " " + String((recording.programmeDescription ?? "").prefix(200)))
        let teams = Dictionary(
            fixtures.filter { leagues.contains($0.leagueId) }.flatMap { [$0.home?.team, $0.away?.team].compactMap(\.self) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        return teams.contains { team in
            SportsMatcher.tokens(for: team, aliases: aliases).contains { haystack.contains(" \($0) ") }
        }
    }
}
