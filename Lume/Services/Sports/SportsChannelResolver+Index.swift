//
//  SportsChannelResolver+Index.swift
//  Lume
//
//  Narrows each fixture to the channels that can match it before any scoring
//  runs. Matching used to score every candidate channel (57k on a large
//  provider) against every fixture — about 1.1M channel-fixture pairs for the
//  Home rail and 11M for the hub's week of fixtures — each a handful of
//  substring scans over the channel's name and guide.
//
//  Every signal the matchers accept names a word the channel's own name or
//  in-window guide text contains: a team token (the matchers need both teams,
//  so the home side alone is a sound filter), a racing series phrase, an
//  umbrella competition phrase, or a remembered pick. All matching is on whole,
//  space-bounded words of `SportsMatcher.normalize`d text, so a channel the
//  index doesn't name would have scored `nil` anyway. The index only removes
//  work; the matchers still decide.
//

import Foundation

nonisolated extension SportsChannelResolver {
    /// The kickoff windows the guide has to cover, merged where they overlap.
    ///
    /// Each window is what the matchers read around one kickoff: programmes
    /// starting from `leadTime` before it to `lateStart` after it, and whatever
    /// is on air at the kickoff itself — both covered by an overlap fetch of
    /// `[kickoff − leadTime, kickoff + lateStart]`. The union window it replaces
    /// ran from the earliest to the latest kickoff in the batch; for a week of
    /// fixtures that was the whole guide.
    static func guideWindows(for fixtures: [SportsFixture]) -> [ClosedRange<Date>] {
        let windows = fixtures
            .map { $0.startDate.addingTimeInterval(-SportsMatcher.leadTime) ... $0.startDate.addingTimeInterval(SportsMatcher.lateStart) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Date>] = []
        for window in windows {
            if let last = merged.last, window.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, window.upperBound)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    /// Which channels contain which words, and which channels each remembered
    /// pick names.
    struct CandidateIndex {
        private var channelsByWord: [Substring: [Int]] = [:]
        private var channelsByKey: [String: [Int]] = [:]
        /// Competition key → the channel keys pinned for it.
        private var pickedKeys: [String: [String]] = [:]

        init(channels: [Channel], guide: [String: [NormalizedCandidate]], pickIndex: [String: String]) {
            // Guide words once per EPG channel id: many streams share one.
            var guideWords: [String: Set<Substring>] = [:]
            for (channelId, listings) in guide {
                var words = Set<Substring>()
                for listing in listings {
                    words.formUnion(listing.normalizedTitle.split(separator: " "))
                    words.formUnion(listing.normalizedSubtitle.split(separator: " "))
                    words.formUnion(listing.normalizedDescription.split(separator: " "))
                }
                guideWords[channelId] = words
            }

            for (index, channel) in channels.enumerated() {
                var words = Set(channel.nameHaystack.split(separator: " "))
                if let channelId = channel.summary.epgChannelId, let fromGuide = guideWords[channelId] {
                    words.formUnion(fromGuide)
                }
                for word in words {
                    channelsByWord[word, default: []].append(index)
                }
                channelsByKey[channel.key, default: []].append(index)
            }

            for composite in pickIndex.keys {
                // "<competitionKey>|<channelKey>": competition ids carry no "|",
                // while a folded channel name ("DE | Sky Sport") can.
                guard let separator = composite.firstIndex(of: "|") else { continue }
                let competition = String(composite[..<separator])
                pickedKeys[competition, default: []].append(String(composite[composite.index(after: separator)...]))
            }
        }

        /// Channels whose name or guide contains the first word of any phrase —
        /// a superset of those containing the whole phrase.
        func channels(mentioningAnyOf phrases: some Sequence<String>) -> Set<Int> {
            var result = Set<Int>()
            for phrase in phrases {
                guard let first = phrase.split(separator: " ").first else { continue }
                result.formUnion(channelsByWord[first] ?? [])
            }
            return result
        }

        /// Channels pinned for `competitionKey`.
        func pickedChannels(competitionKey: String) -> Set<Int> {
            var result = Set<Int>()
            for key in pickedKeys[competitionKey] ?? [] {
                result.formUnion(channelsByKey[key] ?? [])
            }
            return result
        }

        /// The channels worth scoring for `fixture`, in their original order, so
        /// ties rank exactly as when every channel was scored.
        func candidates(for fixture: SportsFixture) -> [Int] {
            var result = pickedChannels(competitionKey: fixture.leagueId)
            if let home = fixture.home?.team, fixture.away?.team != nil {
                result.formUnion(channels(mentioningAnyOf: SportsMatcher.tokens(for: home)))
                result.formUnion(channels(mentioningAnyOf: SportsCompetitionMatcher.phrases(leagueId: fixture.leagueId)))
            } else {
                result.formUnion(channels(mentioningAnyOf: SportsRaceMatcher.seriesPhrases(leagueId: fixture.leagueId)))
            }
            return result.sorted()
        }
    }
}
