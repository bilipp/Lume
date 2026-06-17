//
//  RecommendationVote.swift
//  Lume
//
//  A user's up/down vote on a "For You" recommendation. Stored as part of the
//  per-content user state (`Movie`/`Series.recommendationVoteRaw`, mirrored to
//  `UserContentState`), so a vote syncs across the user's devices via iCloud
//  alongside favorites and watch progress. The absence of a vote is the raw
//  value `0`; `RecommendationVote(rawValue:)` maps it back to `nil`.
//

import Foundation

enum RecommendationVote: Int, Codable {
    case upvote = 1
    case downvote = -1
}
