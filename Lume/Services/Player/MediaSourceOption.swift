//
//  MediaSourceOption.swift
//  Lume
//
//  One playable version of a Jellyfin/Emby title as the source picker shows
//  it, built from the server's `MediaSources`. AIOStreams-style versions are
//  described from their parsed release (`aiostreams` extension); a stock
//  server's from the file's own streams. Placeholder entries — a server's
//  notices — never become an option.
//
//  Also home to the rules that skip the picker (`MediaSourceAutoPick`) and the
//  per-device memory of what was picked (`MediaSourcePreferences`).
//

import Foundation

nonisolated struct MediaSourceOption: Identifiable, Hashable {
    /// Stable across listings of the title: AIOStreams' own version id, else
    /// the source id. What a remembered pick and a failed mark are keyed by.
    let id: String
    /// What the stream URL's `MediaSourceId` carries.
    let mediaSourceId: String
    /// `4K`, `1080p`, `720p`, `SD`.
    let resolution: String?
    /// Technical release tags: `REMUX`, `HDR10`, `DV`, `TrueHD`, …
    let tags: [String]
    let sizeBytes: Int64?
    /// `true` when a debrid service already holds the file, so it starts at
    /// once; `nil` when the server doesn't say.
    let isCached: Bool?
    /// `RealDebrid · Torrentio` — where the stream comes from.
    let provider: String?
    /// The server's own label for the version, shown as-is under the headline.
    let label: String?
    let bingeGroup: String?

    init(source: JellyfinMediaSource) {
        let ext = source.aiostreams
        id = ext?.id.flatMap { $0.isEmpty ? nil : $0 } ?? source.id
        mediaSourceId = source.id
        let video = source.mediaStreams.first { $0.type == "Video" }
        resolution = Self.resolutionLabel(ext?.resolution) ?? Self.resolutionLabel(height: video?.height)
        tags = ext.map(Self.releaseTags) ?? Self.streamTags(source.mediaStreams)
        sizeBytes = (source.size ?? ext?.size).flatMap { $0 > 0 ? $0 : nil }
        isCached = ext?.cached
        let service = ext?.service.flatMap(Self.serviceName)
        let addon = ext?.addon.flatMap { $0.isEmpty ? nil : $0 }
        let parts = [service, addon].compactMap(\.self)
        provider = parts.isEmpty ? nil : parts.joined(separator: " · ")
        let name = source.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        label = (name?.isEmpty == false ? name : nil) ?? ext?.description
        bingeGroup = ext?.bingeGroup.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The playable versions of a `PlaybackInfo` answer, in the server's
    /// order (AIOStreams ranks them). A repeated id keeps its first entry.
    static func options(from sources: [JellyfinMediaSource]) -> [MediaSourceOption] {
        var seen = Set<String>()
        return sources.filter { !$0.isPlaceholder }.map(MediaSourceOption.init).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Description

    static func resolutionLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty, raw != "unknown" else { return nil }
        switch raw {
        case "2160p", "4k", "uhd": return "4K"
        case "4320p", "8k": return "8K"
        case "576p", "480p", "360p", "240p", "144p", "sd": return "SD"
        default: return raw.hasSuffix("p") ? raw : raw.uppercased()
        }
    }

    static func resolutionLabel(height: Int?) -> String? {
        guard let height, height > 0 else { return nil }
        switch height {
        case 3000...: return "8K"
        case 1800...: return "4K"
        case 1300...: return "1440p"
        case 1000...: return "1080p"
        case 700...: return "720p"
        default: return "SD"
        }
    }

    /// The parsed release, in reading order, with Dolby's trademarks mapped to
    /// technical tokens (Lume shows no Dolby word marks) and duplicates and
    /// non-information (`Unknown`, `SDR`) dropped.
    private static func releaseTags(_ ext: JellyfinSourceExtension) -> [String] {
        let raw = [ext.quality, ext.encode].compactMap(\.self) + ext.visualTags + ext.audioTags
        return uniqueTags(raw.compactMap(technicalTag))
    }

    /// A stock server's version: video range, then video and audio codecs.
    private static func streamTags(_ streams: [JellyfinMediaStream]) -> [String] {
        let video = streams.first { $0.type == "Video" }
        let audio = streams.first { $0.type == "Audio" }
        let range = video?.videoRangeType.flatMap(videoRangeTag)
        return uniqueTags([range, video?.codec.flatMap(codecTag), audio?.codec.flatMap(codecTag)].compactMap(\.self))
    }

    private static func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return Array(tags.filter { seen.insert($0.lowercased()).inserted }.prefix(6))
    }

    static func technicalTag(_ raw: String) -> String? {
        let tag = raw.trimmingCharacters(in: .whitespaces)
        let key = tag.lowercased()
        switch key {
        case "", "unknown", "sdr", "none": return nil
        case "dv", "dovi", "dolby vision", "dolbyvision": return "DV"
        case "dd+", "ddp", "dd+ atmos", "eac3", "e-ac3", "dolby digital plus": return "E-AC-3"
        case "dd", "ac3", "dolby digital": return "AC-3"
        case "truehd", "true hd", "truehd atmos": return "TrueHD"
        case "hdr10+", "hdr10plus": return "HDR10+"
        default:
            // Anything else naming Dolby (Atmos above all) has no technical
            // equivalent without its codec, which the codec tag already gives.
            if key.contains("atmos") || key.contains("dolby") { return nil }
            return tag
        }
    }

    private static func videoRangeTag(_ raw: String) -> String? {
        let key = raw.uppercased()
        if key.hasPrefix("DOVI") { return "DV" }
        switch key {
        case "HDR10": return "HDR10"
        case "HDR10PLUS": return "HDR10+"
        case "HLG": return "HLG"
        default: return nil
        }
    }

    private static func codecTag(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        return codecNames[raw.lowercased()] ?? raw.uppercased()
    }

    private static let codecNames = [
        "hevc": "HEVC", "h265": "HEVC", "h264": "H.264", "avc": "H.264", "av1": "AV1", "vp9": "VP9",
        "eac3": "E-AC-3", "ac3": "AC-3", "truehd": "TrueHD", "dts": "DTS", "aac": "AAC",
        "flac": "FLAC", "opus": "Opus", "mp3": "MP3"
    ]

    /// Display names for the services AIOStreams reports by id. Brand names,
    /// shown verbatim; an id Lume doesn't know is shown as sent.
    static func serviceName(_ id: String) -> String? {
        let names = [
            "realdebrid": "RealDebrid", "alldebrid": "AllDebrid", "premiumize": "Premiumize",
            "debridlink": "Debrid-Link", "torbox": "TorBox", "easydebrid": "EasyDebrid",
            "offcloud": "Offcloud", "pikpak": "PikPak", "seedr": "Seedr", "putio": "put.io",
            "stremthru": "StremThru", "easynews": "Easynews", "nzbdav": "NzbDAV", "altmount": "AltMount",
            "debrider": "Debrider"
        ]
        let key = id.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return names[key.lowercased()] ?? key
    }
}

// MARK: - Skipping the picker

nonisolated enum MediaSourceAutoPick {
    struct Context {
        /// The "Choose Source Before Playing" setting.
        var choosesBeforePlaying: Bool
        /// Whether playback resumes partway in, which reuses the last pick.
        var isResuming: Bool
        /// The version last picked for this title on this device.
        var rememberedId: String?
        /// The release group this player session last played, for an episode
        /// it moved on to.
        var bingeGroup: String?
        /// Versions that already failed to start this session.
        var failedIds: Set<String> = []
    }

    /// The version to play without asking, or `nil` to show the picker.
    ///
    /// Once a version has failed the viewer always chooses: playing the next
    /// one silently would hide which release is broken.
    static func pick(from options: [MediaSourceOption], context: Context) -> MediaSourceOption? {
        guard !options.isEmpty, context.failedIds.isEmpty else { return nil }
        if context.isResuming, let remembered = context.rememberedId,
           let match = options.first(where: { $0.id == remembered })
        {
            return match
        }
        if let group = context.bingeGroup, let match = options.first(where: { $0.bingeGroup == group }) {
            return match
        }
        if options.count == 1 || !context.choosesBeforePlaying {
            return options.first
        }
        return nil
    }
}

// MARK: - Remembered picks

/// The version last picked per title, on this device only. A small capped map
/// in `UserDefaults`: a pick is a preference for a list that changes under it
/// (a cached release can drop out), never a key into it.
nonisolated enum MediaSourcePreferences {
    static let storageKey = "player.mediaSourcePicks"
    static let capacity = 200

    struct Entry: Codable, Equatable {
        var sourceId: String
        var pickedAt: Date
    }

    static func rememberedSourceId(for ref: PlayableMedia.ContentRef, defaults: UserDefaults = .standard) -> String? {
        guard let key = key(for: ref) else { return nil }
        return load(defaults)[key]?.sourceId
    }

    static func remember(_ sourceId: String, for ref: PlayableMedia.ContentRef, at date: Date = Date(), defaults: UserDefaults = .standard) {
        guard let key = key(for: ref) else { return }
        var entries = load(defaults)
        entries[key] = Entry(sourceId: sourceId, pickedAt: date)
        if entries.count > capacity {
            let evicted = entries.sorted { $0.value.pickedAt < $1.value.pickedAt }.prefix(entries.count - capacity)
            for (key, _) in evicted {
                entries.removeValue(forKey: key)
            }
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func key(for ref: PlayableMedia.ContentRef) -> String? {
        switch ref {
        case let .movie(id), let .episode(id): id
        case .live, .recording: nil
        }
    }

    private static func load(_ defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}
