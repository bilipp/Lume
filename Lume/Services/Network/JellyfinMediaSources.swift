//
//  JellyfinMediaSources.swift
//  Lume
//
//  The `PlaybackInfo` wire types: an item's versions (`MediaSources`) as a
//  Jellyfin or Emby server lists them. A stock server lists one per file it
//  holds for the title; an AIOStreams-style server lists every stream its
//  addons found, each carrying an `aiostreams` extension object, and appends
//  its notices as `Type: "Placeholder"` entries.
//
//  Decoded leniently: one odd field in one version must not drop the whole
//  list, so every optional field is read with `try?`.
//

import Foundation

nonisolated struct JellyfinPlaybackInfoRequest: Encodable {
    let userId: String
    let isPlayback: Bool
    let fresh: Bool
    let refresh: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "UserId"
        case isPlayback = "IsPlayback"
        case fresh = "Fresh"
        case refresh = "Refresh"
    }
}

nonisolated struct JellyfinPlaybackInfo: Decodable {
    let mediaSources: [JellyfinMediaSource]
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case errorCode = "ErrorCode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaSources = (try? container.decode([LenientSource].self, forKey: .mediaSources))?.compactMap(\.source) ?? []
        errorCode = try? container.decodeIfPresent(String.self, forKey: .errorCode)
    }

    /// One undecodable entry yields `nil` instead of failing its siblings.
    private struct LenientSource: Decodable {
        let source: JellyfinMediaSource?

        init(from decoder: Decoder) throws {
            source = try? JellyfinMediaSource(from: decoder)
        }
    }
}

nonisolated struct JellyfinMediaSource: Decodable, Hashable {
    /// What the stream URL's `MediaSourceId` names. The first version's is the
    /// item's own id, so it is not unique across listings of a title.
    let id: String
    let name: String?
    /// `Default` for a playable version, `Placeholder` for a notice.
    let type: String?
    let container: String?
    let size: Int64?
    let mediaStreams: [JellyfinMediaStream]
    let aiostreams: JellyfinSourceExtension?

    var isPlaceholder: Bool {
        type?.caseInsensitiveCompare("Placeholder") == .orderedSame
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case container = "Container"
        case size = "Size"
        case mediaStreams = "MediaStreams"
        case aiostreams
    }

    init(
        id: String,
        name: String? = nil,
        type: String? = "Default",
        container: String? = nil,
        size: Int64? = nil,
        mediaStreams: [JellyfinMediaStream] = [],
        aiostreams: JellyfinSourceExtension? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.container = container
        self.size = size
        self.mediaStreams = mediaStreams
        self.aiostreams = aiostreams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        self.container = try? container.decodeIfPresent(String.self, forKey: .container)
        size = container.lenientInt64(forKey: .size)
        mediaStreams = (try? container.decodeIfPresent([JellyfinMediaStream].self, forKey: .mediaStreams)) ?? []
        aiostreams = try? container.decodeIfPresent(JellyfinSourceExtension.self, forKey: .aiostreams)
    }
}

nonisolated struct JellyfinMediaStream: Decodable, Hashable {
    /// `Video`, `Audio` or `Subtitle`.
    let type: String?
    let codec: String?
    let height: Int?
    let displayTitle: String?
    /// `SDR`, `HDR10`, `DOVI`, `HLG`, … on video streams.
    let videoRangeType: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case height = "Height"
        case displayTitle = "DisplayTitle"
        case videoRangeType = "VideoRangeType"
    }

    init(type: String?, codec: String? = nil, height: Int? = nil, displayTitle: String? = nil, videoRangeType: String? = nil) {
        self.type = type
        self.codec = codec
        self.height = height
        self.displayTitle = displayTitle
        self.videoRangeType = videoRangeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        codec = try? container.decodeIfPresent(String.self, forKey: .codec)
        height = container.lenientInt64(forKey: .height).map { Int($0) }
        displayTitle = try? container.decodeIfPresent(String.self, forKey: .displayTitle)
        videoRangeType = try? container.decodeIfPresent(String.self, forKey: .videoRangeType)
    }
}

/// AIOStreams' per-version extension (its `versions` feature): the parsed
/// release next to the label its formatter wrote.
nonisolated struct JellyfinSourceExtension: Decodable, Hashable {
    /// The version's own id, stable across listings — what a remembered pick
    /// is matched against.
    let id: String?
    let name: String?
    let description: String?
    let addon: String?
    /// A debrid/usenet service id such as `realdebrid` or `torbox`.
    let service: String?
    let cached: Bool?
    let resolution: String?
    let quality: String?
    let encode: String?
    let visualTags: [String]
    let audioTags: [String]
    let size: Int64?
    /// Stremio's: the next episode's version in the same group plays on.
    let bingeGroup: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, addon, service, cached, resolution, quality, encode
        case visualTags, audioTags, size, bingeGroup
    }

    init(
        id: String? = nil,
        name: String? = nil,
        description: String? = nil,
        addon: String? = nil,
        service: String? = nil,
        cached: Bool? = nil,
        resolution: String? = nil,
        quality: String? = nil,
        encode: String? = nil,
        visualTags: [String] = [],
        audioTags: [String] = [],
        size: Int64? = nil,
        bingeGroup: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.addon = addon
        self.service = service
        self.cached = cached
        self.resolution = resolution
        self.quality = quality
        self.encode = encode
        self.visualTags = visualTags
        self.audioTags = audioTags
        self.size = size
        self.bingeGroup = bingeGroup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        addon = try? container.decodeIfPresent(String.self, forKey: .addon)
        service = try? container.decodeIfPresent(String.self, forKey: .service)
        cached = try? container.decodeIfPresent(Bool.self, forKey: .cached)
        resolution = try? container.decodeIfPresent(String.self, forKey: .resolution)
        quality = try? container.decodeIfPresent(String.self, forKey: .quality)
        encode = try? container.decodeIfPresent(String.self, forKey: .encode)
        visualTags = (try? container.decodeIfPresent([String].self, forKey: .visualTags)) ?? []
        audioTags = (try? container.decodeIfPresent([String].self, forKey: .audioTags)) ?? []
        size = container.lenientInt64(forKey: .size)
        bingeGroup = try? container.decodeIfPresent(String.self, forKey: .bingeGroup)
    }
}

private nonisolated extension KeyedDecodingContainer {
    /// Sizes arrive as integers from Jellyfin and as JSON numbers that may
    /// carry a fraction from AIOStreams.
    func lenientInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int64(value)
        }
        return nil
    }
}
