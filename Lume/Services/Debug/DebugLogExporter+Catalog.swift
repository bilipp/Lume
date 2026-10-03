//
//  DebugLogExporter+Catalog.swift
//  Lume
//
//  The report's "Playlists" section: per playlist its kind, sync state,
//  account state and content counts — never its name, address or credentials.
//  Reads through its own `ModelContext`, off the main actor.
//

import Foundation
import SwiftData

nonisolated extension DebugLogExporter {
    static func catalogLines(container: ModelContainer, now: Date, compact: Bool = false) -> [String] {
        let context = ModelContext(container)
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
        guard !playlists.isEmpty else { return ["No playlists added."] }
        let epgSources = (try? context.fetch(FetchDescriptor<EPGSource>())) ?? []

        var lines: [String] = []
        for (index, playlist) in playlists.enumerated() {
            var head = "#\(index + 1) \(playlist.sourceType.rawValue) · \(playlist.syncStatus.rawValue) · last sync \(ago(playlist.lastSyncDate, now: now))"
            if !playlist.syncEnabled { head += " · sync off" }
            lines.append(head)
            guard !compact else { continue }
            lines.append("   address: \(NetworkDiagnostics.shape(of: playlist.serverURL))")
            if let account = accountLine(playlist, now: now) { lines.append(account) }
            lines.append("   content: \(contentCounts(playlistID: playlist.id, context: context))")
            lines += epgSources.filter { $0.playlistID == playlist.id }.map { guideLine($0, now: now) }
        }
        let unattached = epgSources.count(where: { source in !playlists.contains { $0.id == source.playlistID } })
        if unattached > 0, !compact {
            lines.append("Standalone guides: \(unattached)")
        }
        return lines
    }

    private static func ago(_ date: Date?, now: Date) -> String {
        date.map { "\(DeviceDiagnostics.durationString(now.timeIntervalSince($0))) ago" } ?? "never"
    }

    private static func accountLine(_ playlist: Playlist, now: Date) -> String? {
        var account: [String] = []
        if let status = playlist.userStatus { account.append("status \(status)") }
        if let expiry = playlist.expDate { account.append("expires \(expiryDescription(expiry, now: now))") }
        if let max = playlist.maxConnections { account.append("connections \(playlist.activeConnections ?? "?")/\(max)") }
        if let timezone = playlist.serverTimezone { account.append("server tz \(timezone)") }
        if let outputs = playlist.allowedOutputFormatsRaw { account.append("outputs \(outputs)") }
        if playlist.streamFormat != .automatic { account.append("format \(playlist.streamFormat.rawValue)") }
        return account.isEmpty ? nil : "   account: \(account.joined(separator: " · "))"
    }

    private static func guideLine(_ guide: EPGSource, now: Date) -> String {
        let kind = guide.isManual ? "manual" : "provider"
        let enabled = guide.isEnabled ? "" : " · disabled"
        return "   guide (\(kind)): \(guide.syncStatus.rawValue) · last sync \(ago(guide.lastSyncDate, now: now)) · \(NetworkDiagnostics.shape(of: guide.url))\(enabled)"
    }

    private static func contentCounts(playlistID: UUID, context: ModelContext) -> String {
        let prefix = playlistID.uuidString
        let live = (try? context.fetchCount(FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) }))) ?? 0
        let movies = (try? context.fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) }))) ?? 0
        let series = (try? context.fetchCount(FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) }))) ?? 0
        let episodes = (try? context.fetchCount(FetchDescriptor<Episode>(predicate: #Predicate { $0.id.starts(with: prefix) }))) ?? 0
        return "\(live) live · \(movies) movies · \(series) series · \(episodes) episodes"
    }

    /// Xtream sends a Unix timestamp; show it as a date plus "EXPIRED" when due.
    private static func expiryDescription(_ raw: String, now: Date) -> String {
        guard let seconds = TimeInterval(raw), seconds > 0 else { return raw.isEmpty ? "unknown" : raw }
        let date = Date(timeIntervalSince1970: seconds)
        let day = date.formatted(.iso8601.year().month().day())
        return date < now ? "\(day) (EXPIRED)" : day
    }
}
