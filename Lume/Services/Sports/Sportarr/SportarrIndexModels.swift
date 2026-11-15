//
//  SportarrIndexModels.swift
//  Lume
//
//  Disposable per-playlist derived metadata. A cache loss never deletes a
//  catalog row or changes which file plays; the next normal scan rebuilds it.
//

import CryptoKit
import Foundation

nonisolated enum SportarrFileKind: String, Codable, Hashable {
    case movie, episode
}

nonisolated enum SportarrResolutionState: String, Codable, Hashable {
    case pending, resolved, notFound, rejected
}

nonisolated struct SportarrImportFile: Codable, Hashable {
    let catalogID: String
    let kind: SportarrFileKind
    let eventID: String?
    let title: String
    let date: Date?
    let seriesID: String?
    let seriesTitle: String?
    let leagueID: String?
    let libraryTitle: String?
    let seasonNumber: Int?
    let fileName: String
    let fingerprint: String

    static func fingerprint(path: String?, created: String?, duration: Int64?, eventID: String?) -> String {
        var identity = path ?? ""
        if var url = path.flatMap(URLComponents.init(string:)), url.scheme != nil {
            url.query = nil
            url.fragment = nil
            url.user = nil
            url.password = nil
            identity = url.string ?? identity
        }
        let parts = [identity, created ?? "", duration.map(String.init) ?? "", eventID ?? ""]
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct SportarrIndexedFile: Codable, Hashable {
    static let resolverVersion = 1

    var file: SportarrImportFile
    var metadata: SportarrEpisode?
    var fixture: SportsFixture?
    var espnLeagueID: String?
    var matchedFromTitle = false
    var resolution: SportarrResolutionState = .pending
    var resolvedVersion = 0
    var lookupFailures = 0
    var nextLookupAt: Date?

    init(file: SportarrImportFile) {
        self.file = file
    }

    func needsLookup(now: Date) -> Bool {
        guard file.eventID != nil else { return false }
        if resolvedVersion != Self.resolverVersion { return true }
        if resolution == .resolved { return false }
        return nextLookupAt.map { now >= $0 } ?? true
    }

    /// A renamed display title can update without looking up the same file
    /// again. A server-reported file/identifier change resets derived answers.
    mutating func update(_ incoming: SportarrImportFile) {
        if incoming.fingerprint != file.fingerprint || incoming.eventID != file.eventID {
            self = Self(file: incoming)
        } else {
            file = incoming
        }
    }

    mutating func apply(_ result: SportarrLookup<SportarrEpisode>, now: Date) {
        switch result {
        case let .found(answer): accept(answer, now: now)
        case .missing: noteMiss(now: now)
        case .unavailable, .disabled: break
        }
    }

    private mutating func accept(_ answer: SportarrEpisode, now: Date) {
        guard let expected = file.eventID, answer.id?.lowercased() == expected.lowercased(), answer.agrees(with: file.date) else {
            noteMiss(now: now, rejected: true)
            return
        }
        metadata = answer
        fixture = nil
        matchedFromTitle = false
        resolution = .resolved
        resolvedVersion = Self.resolverVersion
        lookupFailures = 0
        nextLookupAt = nil
    }

    private mutating func noteMiss(now: Date, rejected: Bool = false) {
        resolution = rejected ? .rejected : .notFound
        resolvedVersion = Self.resolverVersion
        lookupFailures = min(max(lookupFailures, 0), 30) + 1
        let interval = min(7 * 86400.0, 3600 * pow(2, Double(min(lookupFailures - 1, 8))))
        nextLookupAt = now.addingTimeInterval(interval)
    }
}

nonisolated struct SportarrPlaylistIndex: Codable {
    static let schemaVersion = 1
    var version = Self.schemaVersion
    let playlistID: UUID
    var files: [String: SportarrIndexedFile] = [:]
    var sportsSeries: [String: SportarrSeriesReference] = [:]
    var leagues: [String: SportarrSeries] = [:]
    var seasons: [String: [SportarrEpisode]] = [:]
    var historicalFixtures: [String: [SportsFixture]] = [:]
}

nonisolated extension SportarrPlaylistIndex {
    mutating func mergeImported(_ incoming: [String: SportarrImportFile], series: [String: SportarrSeriesReference], removedIDs: Set<String>, removedSeries: Set<String>) {
        sportsSeries.merge(series, uniquingKeysWith: { _, new in new })
        for (key, file) in incoming {
            if files[key] != nil {
                files[key]?.update(file)
            } else {
                files[key] = SportarrIndexedFile(file: file)
            }
        }
        let removed = removedIDs.subtracting(incoming.keys)
        let revived = Set(incoming.values.compactMap(\.seriesID)).union(series.keys)
        let withdrawn = removedSeries.subtracting(revived)
        files = files.filter { key, record in
            !removed.contains(key) && !(record.file.seriesID.map(withdrawn.contains) ?? false)
        }
        sportsSeries = sportsSeries.filter { !withdrawn.contains($0.key) }
    }
}
