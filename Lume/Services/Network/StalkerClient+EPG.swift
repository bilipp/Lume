//
//  StalkerClient+EPG.swift
//  Lume
//
//  The portal's own programme guide (`itv get_epg_info`). Stalker portals
//  expose no XMLTV file, and most of their channels carry no `xmltv_id`, so
//  this is the only guide such a playlist has.
//
//  The call is heavy for the portal: it runs one query per channel for the
//  whole lineup and caches nothing, and `period` (hours ahead, plus two the
//  server adds) has no cap. `EPGSyncManager` therefore makes it once per guide
//  refresh, never on launch or on a zap.
//

import Foundation

extension StalkerClient {
    /// Every programme the portal lists for the subscription's channels over
    /// the next `periodHours` (+2) hours.
    func getEPGInfo(periodHours: Int) async throws -> [StalkerEPGProgramme] {
        let envelope: StalkerEnvelope<StalkerEPGInfo> = try await request(
            type: "itv",
            action: "get_epg_info",
            extraQuery: [URLQueryItem(name: "period", value: String(periodHours))]
        )
        return envelope.js.programmes
    }
}

/// `get_epg_info`'s `js` payload. `data` is normally an object keyed by channel
/// id, each holding that channel's programmes; PHP encodes an empty one as
/// `[]`, and some portals send an array of per-channel arrays or one flat list.
nonisolated struct StalkerEPGInfo: Decodable {
    let programmes: [StalkerEPGProgramme]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let byChannel = try? container.decode([String: [StalkerEPGProgramme]].self, forKey: .data) {
            programmes = byChannel.flatMap { key, list in list.map { $0.withChannelId(fallback: key) } }
        } else if let nested = try? container.decode([[StalkerEPGProgramme]].self, forKey: .data) {
            programmes = nested.flatMap(\.self)
        } else {
            programmes = (try? container.decode([StalkerEPGProgramme].self, forKey: .data)) ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case data
    }
}

/// One guide entry. Only the unix timestamps are read: `time`/`time_to` are
/// strings in the portal's own time zone, and `stop_timestamp` can be 0.
nonisolated struct StalkerEPGProgramme: Decodable {
    let channelId: String?
    let title: String?
    let description: String?
    let category: String?
    let start: Int?
    let stop: Int?

    init(
        channelId: String?,
        title: String?,
        description: String? = nil,
        category: String? = nil,
        start: Int?,
        stop: Int?
    ) {
        self.channelId = channelId
        self.title = title
        self.description = description
        self.category = category
        self.start = start
        self.stop = stop
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = container.stalkerString(.channelId)
        title = container.stalkerString(.title)
        description = container.stalkerString(.description)
        category = container.stalkerString(.category)
        start = container.stalkerInt(.start)
        stop = container.stalkerInt(.stop)
    }

    func withChannelId(fallback: String) -> StalkerEPGProgramme {
        guard channelId?.isEmpty ?? true else { return self }
        return StalkerEPGProgramme(
            channelId: fallback,
            title: title,
            description: description,
            category: category,
            start: start,
            stop: stop
        )
    }

    enum CodingKeys: String, CodingKey {
        case channelId = "ch_id"
        case title = "name"
        case description = "descr"
        case category
        case start = "start_timestamp"
        case stop = "stop_timestamp"
    }
}
