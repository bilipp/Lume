//
//  StalkerPortalGuide.swift
//  Lume
//
//  How a Stalker portal's own guide (`get_epg_info`) plugs into the XMLTV
//  pipeline. The playlist gets a linked `EPGSource` whose URL is a marker
//  rather than a download, and every channel gets an EPG channel id: its
//  `xmltv_id` when the portal sends one, so an attached XMLTV file still
//  matches it, or a key built from the playlist and the portal's channel id.
//

import Foundation

nonisolated enum StalkerPortalGuide {
    /// Hours ahead each refresh asks for; the portal adds two.
    static let periodHours = 24

    private static let scheme = "stalker-portal"

    /// The linked source's URL. Never downloaded, never shown: EPG settings
    /// label a playlist-linked source "From playlist".
    static func sourceURL(playlistID: UUID) -> String {
        "\(scheme)://\(playlistID.uuidString)"
    }

    /// The playlist a portal-guide source belongs to, or nil for an XMLTV URL.
    static func playlistID(fromSourceURL url: String) -> UUID? {
        let prefix = "\(scheme)://"
        guard url.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(url.dropFirst(prefix.count)))
    }

    /// The EPG channel id of a channel with no `xmltv_id`. Scoped to the
    /// playlist, since two portals reuse the same channel ids.
    static func channelKey(playlistID: UUID, streamId: Int) -> String {
        "stalker-\(playlistID.uuidString)-\(streamId)"
    }

    /// A channel's EPG channel id: its `xmltv_id`, else the portal key.
    static func epgChannelId(xmltvId: String?, playlistID: UUID, streamId: Int) -> String {
        if let xmltvId, !xmltvId.isEmpty { return xmltvId }
        return channelKey(playlistID: playlistID, streamId: streamId)
    }

    /// The portal's programmes as XMLTV ones, on the EPG channel id of the
    /// channel each belongs to. `channelKeys` maps a channel's `streamId` to
    /// that id (the portal's `ch_id` maps to `streamId` as the channel sync
    /// maps a channel's `id`); a programme on a channel not stored is dropped.
    ///
    /// A missing or zero stop time ends the programme where the next one on
    /// its channel starts; the last one on a channel without a stop is
    /// dropped, as is anything without a title or with a non-positive length.
    static func programmes(
        from entries: [StalkerEPGProgramme],
        channelKeys: [Int: String]
    ) -> [ParsedProgramme] {
        var byChannel: [String: [StalkerEPGProgramme]] = [:]
        for entry in entries {
            guard let rawId = entry.channelId, !rawId.isEmpty,
                  let key = channelKeys[ContentSyncManager.streamId(for: rawId)],
                  let start = entry.start, start > 0,
                  let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { continue }
            byChannel[key, default: []].append(entry)
        }

        var result: [ParsedProgramme] = []
        for (key, list) in byChannel {
            let sorted = list.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
            for (index, entry) in sorted.enumerated() {
                guard let start = entry.start, let title = entry.title else { continue }
                let nextStart = sorted.dropFirst(index + 1).first { ($0.start ?? 0) > start }?.start
                let stop = (entry.stop ?? 0) > start ? entry.stop : nextStart
                guard let stop, stop > start else { continue }
                let category = entry.category?.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ParsedProgramme(
                    channelId: key,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    subtitle: nil,
                    description: entry.description ?? "",
                    categories: category.map { $0.isEmpty ? [] : [$0] } ?? [],
                    start: Date(timeIntervalSince1970: TimeInterval(start)),
                    end: Date(timeIntervalSince1970: TimeInterval(stop))
                ))
            }
        }
        return result
    }
}
