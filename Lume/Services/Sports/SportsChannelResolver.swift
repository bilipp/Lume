//
//  SportsChannelResolver.swift
//  Lume
//
//  Resolves a batch of `SportsFixture`s to the channels in the viewer's own
//  playlists that carry them, entirely off the main thread. Modelled on
//  `ChannelEPGLoader`/`EPGGuideLoader`: it runs on its own `ModelContext` inside
//  a detached task, bounds every fetch, and returns plain `Sendable` value
//  snapshots so nothing managed crosses back to the caller.
//
//  Three passes, in this order because each is cheaper than the last only once
//  the earlier ones have narrowed the work:
//   1. One scoped fetch of candidate `LiveStream`s across *all* playlists —
//      hidden channels and parental-/user-restricted categories excluded in
//      SQLite, not in Swift.
//   2. One `EPGListing` fetch, bounded by the union kickoff window *and* the
//      candidate channel ids, with the wide `listingDescription` column left
//      out — never the unscoped time-only scan that froze the guide.
//   3. Matching in Swift, via the pure `SportsMatcher` token logic, plus the
//      viewer's remembered picks and a channel-name fallback.
//

import Foundation
import SwiftData

// MARK: - Result value types

/// Why a channel was offered for a fixture, ordered by confidence. Its `rank`
/// is the sort key — a lower rank is a stronger signal.
nonisolated enum ResolvedChannelSource: String, Codable, Hashable {
    /// The viewer pinned this channel for the competition.
    case userPick
    /// The EPG programme names both teams together in its title or sub-title —
    /// the fixture line itself.
    case epgTitleSubtitle
    /// The EPG programme names both teams, but split across the title and
    /// sub-title rather than together in one field.
    case epgSingleField
    /// The programme's description names both teams — a multi-game
    /// conference ("Sonntags-Konferenz, 6. Spieltag") whose title says nothing
    /// about this fixture but whose body lists it among the games carried.
    case epgDescription
    /// No EPG match; the channel's own name names both teams
    /// ("DAZN 5 | Bayern vs Dortmund").
    case channelName

    var rank: Int {
        switch self {
        case .userPick: 0
        case .epgTitleSubtitle: 1
        case .epgSingleField: 2
        case .epgDescription: 3
        case .channelName: 4
        }
    }
}

/// A plain snapshot of the fields a resolved channel row needs — enough to
/// render the picker and to re-fetch the `LiveStream` by `id` when the viewer
/// chooses to watch.
nonisolated struct ResolvedStreamSummary: Codable, Hashable {
    let id: String
    let name: String
    let streamIcon: String?
    let epgChannelId: String?
}

/// One channel that can carry a fixture, with why and how well it matched.
nonisolated struct ResolvedChannel: Codable, Hashable, Identifiable {
    let stream: ResolvedStreamSummary
    let playlistID: UUID
    /// The matched EPG programme's title, when the match came from the guide.
    let matchedTitle: String?
    /// The matched programme's start, when known.
    let matchedStart: Date?
    /// Weighted match score, used to order channels within a `source` tier.
    let score: Int
    let source: ResolvedChannelSource
    /// True only when this is the single channel at the strongest tier for its
    /// fixture — the one case a live card offers one-tap playback.
    var isConfident: Bool

    var id: String {
        stream.id
    }
}

// MARK: - Resolver

nonisolated enum SportsChannelResolver {
    /// A visible channel plus the pre-normalised name the channel-name fallback
    /// matches against — built once in pass 1 so a wide fixture batch doesn't
    /// re-fold the same names per fixture.
    private struct Channel {
        let summary: ResolvedStreamSummary
        let playlistID: UUID
        let nameHaystack: String
    }

    /// The `EPGListing` fetch shape, exposed for the query-shape contract test.
    /// Bounded by the kickoff window *and* the candidate channel ids. Unlike the
    /// guide loaders it does fetch `listingDescription`: a conference programme
    /// only names its games there, and the window keeps the row count small.
    nonisolated static func epgCandidateDescriptor(
        channelIds: [String],
        windowStart: Date,
        windowEnd: Date
    ) -> FetchDescriptor<EPGListing> {
        var descriptor = FetchDescriptor<EPGListing>(
            predicate: #Predicate {
                channelIds.contains($0.channelId) && $0.start < windowEnd && $0.end > windowStart
            },
            sortBy: [SortDescriptor(\.channelId), SortDescriptor(\.start)]
        )
        descriptor.propertiesToFetch = [
            \.channelId, \.title, \.subtitle, \.category, \.listingDescription, \.start, \.end
        ]
        return descriptor
    }

    /// The candidate-channel fetch shape: every visible channel across all
    /// playlists, hidden channels and excluded categories dropped in SQLite.
    nonisolated static func candidateStreamDescriptor(
        restriction: ContentRestriction
    ) -> FetchDescriptor<LiveStream> {
        // Optionals so the predicate can test the optional `categoryId` directly
        // against the excluded set — the pattern `LiveChannelNavigator` uses.
        let excluded = Set(restriction.excludedCategoryIDs.map(String?.some))
        let filters = !excluded.isEmpty
        var descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate {
                !$0.isHidden && (!filters || $0.categoryId == nil || !excluded.contains($0.categoryId))
            }
        )
        descriptor.propertiesToFetch = [\.id, \.name, \.streamIcon, \.epgChannelId, \.categoryId]
        return descriptor
    }

    /// Resolves `fixtures` to the channels carrying them, keyed by `fixture.id`.
    ///
    /// `restriction` defaults to permissive so the two-pass fetch is callable in
    /// isolation; the hub passes the active viewer's restriction so a child
    /// profile never sees a locked category's channel. `picks` is read once, up
    /// front, into a `Sendable` snapshot so no `UserDefaults`-bearing value has
    /// to cross into the detached task.
    nonisolated static func resolve(
        container: ModelContainer,
        fixtures: [SportsFixture],
        now: Date,
        restriction: ContentRestriction = ContentRestriction(),
        picks: SportsChannelPicks = SportsChannelPicks()
    ) async -> [String: [ResolvedChannel]] {
        // A finished game has nothing left to watch; skip it before the guide scan.
        let fixtures = fixtures.filter { $0.status.state != .final }
        guard !fixtures.isEmpty else { return [:] }
        let pickIndex = picks.snapshot()

        return await Task.detached(priority: .utility) {
            let interval = Perf.begin(.sportsChannelResolve)
            defer { Perf.end(interval) }

            let context = ModelContext(container)

            // Pass 1 — candidate channels across all playlists.
            let streams = (try? context.fetch(candidateStreamDescriptor(restriction: restriction))) ?? []
            guard !streams.isEmpty else { return [:] }
            let (channels, channelIds) = buildChannels(from: streams)

            // Pass 2 — one bounded EPG fetch over the union kickoff window.
            let kickoffs = fixtures.map(\.startDate)
            let windowStart = (kickoffs.min() ?? now).addingTimeInterval(-SportsMatcher.leadTime)
            let windowEnd = (kickoffs.max() ?? now).addingTimeInterval(SportsMatcher.lateStart)
            let guide = buildGuide(
                context: context, channelIds: channelIds, windowStart: windowStart, windowEnd: windowEnd
            )

            // Pass 3 — match each fixture in Swift.
            var result: [String: [ResolvedChannel]] = [:]
            for fixture in fixtures {
                result[fixture.id] = resolveOne(
                    fixture: fixture,
                    channels: channels,
                    guide: guide,
                    pickIndex: pickIndex
                )
            }
            return result
        }.value
    }

    /// Maps candidate `LiveStream`s to `Channel`s (with normalized name
    /// haystacks) and collects their non-empty EPG channel ids for the Pass 2
    /// fetch.
    private nonisolated static func buildChannels(
        from streams: [LiveStream]
    ) -> (channels: [Channel], channelIds: Set<String>) {
        var channels: [Channel] = []
        channels.reserveCapacity(streams.count)
        var channelIds: Set<String> = []
        for stream in streams {
            guard let playlistID = UUID(uuidString: String(stream.id.prefix(36))) else { continue }
            channels.append(Channel(
                summary: ResolvedStreamSummary(
                    id: stream.id,
                    name: stream.name,
                    streamIcon: stream.streamIcon,
                    epgChannelId: stream.epgChannelId
                ),
                playlistID: playlistID,
                nameHaystack: SportsMatcher.normalize(stream.name)
            ))
            if let cid = stream.epgChannelId, !cid.isEmpty { channelIds.insert(cid) }
        }
        return (channels, channelIds)
    }

    /// An EPG candidate with its title, subtitle and the head of its description
    /// normalized once at guide-build time, so `bestEPGHit` reuses them across
    /// every fixture sharing the channel rather than re-normalizing per fixture.
    private struct NormalizedCandidate {
        let title: String
        let normalizedTitle: String
        let normalizedSubtitle: String
        let normalizedDescription: String
        let start: Date
    }

    /// How much of a description is searched. A conference body lists its games
    /// up front ("Der 6. Spieltag mit Hannover 96 - VfL Bochum, …"); the tail is
    /// commentators and filler.
    private static let descriptionScanLength = 400

    /// Runs the bounded EPG fetch and groups the listings by channel id, folding
    /// each listing's title and subtitle once.
    private nonisolated static func buildGuide(
        context: ModelContext,
        channelIds: Set<String>,
        windowStart: Date,
        windowEnd: Date
    ) -> [String: [NormalizedCandidate]] {
        guard !channelIds.isEmpty else { return [:] }
        let listings = (try? context.fetch(epgCandidateDescriptor(
            channelIds: Array(channelIds), windowStart: windowStart, windowEnd: windowEnd
        ))) ?? []
        var guide: [String: [NormalizedCandidate]] = [:]
        for listing in listings {
            guide[listing.channelId, default: []].append(NormalizedCandidate(
                title: listing.title,
                normalizedTitle: SportsMatcher.normalize(listing.title),
                normalizedSubtitle: SportsMatcher.normalize(listing.subtitle ?? ""),
                normalizedDescription: SportsMatcher.normalize(
                    String(listing.listingDescription.prefix(descriptionScanLength))
                ),
                start: listing.start
            ))
        }
        return guide
    }

    // MARK: - Per-fixture matching

    /// The best EPG signal for one channel and fixture.
    private struct EPGHit {
        let score: Int
        let inOneField: Bool
        /// Both teams were found only in the description — a conference.
        let descriptionOnly: Bool
        let title: String
        let start: Date
    }

    private static func resolveOne(
        fixture: SportsFixture,
        channels: [Channel],
        guide: [String: [NormalizedCandidate]],
        pickIndex: [String: String]
    ) -> [ResolvedChannel] {
        guard let home = fixture.home?.team, let away = fixture.away?.team else { return [] }
        let homeTokens = SportsMatcher.tokens(for: home)
        let awayTokens = SportsMatcher.tokens(for: away)
        guard !homeTokens.isEmpty, !awayTokens.isEmpty else { return [] }

        let context = FixtureMatchContext(
            competitionKey: fixture.leagueId,
            homeTokens: homeTokens,
            awayTokens: awayTokens,
            kickoff: fixture.startDate
        )

        var resolved: [ResolvedChannel] = []
        for channel in channels {
            if let match = matchChannel(channel, context: context, guide: guide, pickIndex: pickIndex) {
                resolved.append(match)
            }
        }

        resolved.sort { lhs, rhs in
            if lhs.source.rank != rhs.source.rank { return lhs.source.rank < rhs.source.rank }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return gap(lhs, context.kickoff) < gap(rhs, context.kickoff)
        }

        // Confident only when a single channel holds the strongest tier alone.
        if let bestRank = resolved.first?.source.rank {
            let atBest = resolved.prefix { $0.source.rank == bestRank }.count
            if atBest == 1 { resolved[0].isConfident = true }
        }
        return resolved
    }

    /// The tokens, competition and kickoff a channel is scored against — bundled
    /// so `matchChannel` stays within the parameter-count limit.
    private struct FixtureMatchContext {
        let competitionKey: String
        let homeTokens: Set<String>
        let awayTokens: Set<String>
        let kickoff: Date
    }

    /// Scores one channel against a fixture, returning the resolved channel or
    /// `nil` when it carries neither a user pick, an EPG hit, nor a name match.
    private static func matchChannel(
        _ channel: Channel,
        context: FixtureMatchContext,
        guide: [String: [NormalizedCandidate]],
        pickIndex: [String: String]
    ) -> ResolvedChannel? {
        let homeTokens = context.homeTokens
        let awayTokens = context.awayTokens
        let channelKey = SportsChannelPicks.channelKey(
            epgChannelId: channel.summary.epgChannelId, name: channel.summary.name
        )
        let isPick = pickIndex[
            SportsChannelPicks.compositeKey(competitionKey: context.competitionKey, channelKey: channelKey)
        ] != nil

        let epg = channel.summary.epgChannelId
            .flatMap { guide[$0] }
            .flatMap { bestEPGHit(in: $0, homeTokens: homeTokens, awayTokens: awayTokens, kickoff: context.kickoff) }
        let nameMatched = teamPresent(homeTokens, in: channel.nameHaystack)
            && teamPresent(awayTokens, in: channel.nameHaystack)

        let source: ResolvedChannelSource
        let score: Int
        if isPick {
            source = .userPick
            score = pickScoreBase + (epg?.score ?? 0)
        } else if let epg {
            source = epg.descriptionOnly ? .epgDescription : (epg.inOneField ? .epgTitleSubtitle : .epgSingleField)
            score = epg.score
        } else if nameMatched {
            source = .channelName
            score = nameMatchScore
        } else {
            return nil
        }

        return ResolvedChannel(
            stream: channel.summary,
            playlistID: channel.playlistID,
            matchedTitle: epg?.title,
            matchedStart: epg?.start,
            score: score,
            source: source,
            isConfident: false
        )
    }

    /// The best-scoring EPG programme for a channel within the kickoff window,
    /// or `nil` when none names both teams. `inOneField` is set when both teams
    /// appear together in the title or the sub-title (the fixture line), the
    /// stronger tier; a programme that names them only in its description — a
    /// conference — still qualifies, as the weakest EPG tier.
    private static func bestEPGHit(
        in candidates: [NormalizedCandidate],
        homeTokens: Set<String>,
        awayTokens: Set<String>,
        kickoff: Date
    ) -> EPGHit? {
        let windowStart = kickoff.addingTimeInterval(-SportsMatcher.leadTime)
        let windowEnd = kickoff.addingTimeInterval(SportsMatcher.lateStart)

        var best: EPGHit?
        for candidate in candidates {
            guard candidate.start >= windowStart, candidate.start <= windowEnd else { continue }
            let title = candidate.normalizedTitle
            let subtitle = candidate.normalizedSubtitle
            let description = candidate.normalizedDescription

            let homeInTitle = teamPresent(homeTokens, in: title)
            let homeInSub = teamPresent(homeTokens, in: subtitle)
            let awayInTitle = teamPresent(awayTokens, in: title)
            let awayInSub = teamPresent(awayTokens, in: subtitle)
            let homeInHeadline = homeInTitle || homeInSub
            let awayInHeadline = awayInTitle || awayInSub
            let homeInBody = homeInHeadline || teamPresent(homeTokens, in: description)
            let awayInBody = awayInHeadline || teamPresent(awayTokens, in: description)
            guard homeInBody, awayInBody else { continue }

            let inOneField = (homeInTitle && awayInTitle) || (homeInSub && awayInSub)
            let descriptionOnly = !(homeInHeadline && awayInHeadline)
            let score = (homeInSub ? subtitleWeight : 0) + (awayInSub ? subtitleWeight : 0)
                + (homeInTitle ? titleWeight : 0) + (awayInTitle ? titleWeight : 0)
                + (descriptionOnly ? descriptionWeight : 0)
            let hit = EPGHit(
                score: score,
                inOneField: inOneField,
                descriptionOnly: descriptionOnly,
                title: candidate.title,
                start: candidate.start
            )

            if isBetterHit(hit, than: best, kickoff: kickoff) { best = hit }
        }
        return best
    }

    private static func isBetterHit(_ lhs: EPGHit, than rhs: EPGHit?, kickoff: Date) -> Bool {
        guard let rhs else { return true }
        if lhs.descriptionOnly != rhs.descriptionOnly { return !lhs.descriptionOnly }
        if lhs.inOneField != rhs.inOneField { return lhs.inOneField }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return abs(lhs.start.timeIntervalSince(kickoff)) < abs(rhs.start.timeIntervalSince(kickoff))
    }

    private static func gap(_ channel: ResolvedChannel, _ kickoff: Date) -> TimeInterval {
        guard let start = channel.matchedStart else { return .greatestFiniteMagnitude }
        return abs(start.timeIntervalSince(kickoff))
    }

    /// A team is present when any distinctive token appears as a whole word.
    /// `haystack` must already be `SportsMatcher.normalize`d (space-padded).
    private static func teamPresent(_ tokens: Set<String>, in haystack: String) -> Bool {
        tokens.contains { haystack.contains(" \($0) ") }
    }

    // Mirror `SportsMatcher`'s field weights so the EPG tier ordering agrees
    // with the matcher's own scoring; a user pick outscores any EPG match, and
    // a channel-name-only hit is the weakest positive signal.
    private static let subtitleWeight = 3
    private static let titleWeight = 2
    private static let descriptionWeight = 1
    private static let pickScoreBase = 1000
    private static let nameMatchScore = 1
}
