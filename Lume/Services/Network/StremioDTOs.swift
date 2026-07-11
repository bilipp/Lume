//
//  StremioDTOs.swift
//  Lume
//
//  Decodable models for the Stremio Addon Protocol. Real-world addons drift
//  from the spec — `imdbRating` arrives as a string or a number, videos use
//  `title` or `name` and `episode` or `number`, and `resources` mixes plain
//  strings with objects — so the DTOs decode those fields flexibly and treat
//  everything beyond identity fields as optional.
//

import Foundation

// MARK: - Flexible decoding

/// A value addons send as either a string or a number; decodes to `String`.
nonisolated struct StremioString: Decodable, Equatable {
    let value: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes a `String` from a field an addon may send as a string or a
    /// number, returning `nil` when the key is absent or null.
    nonisolated func stremioString(_ key: Key) -> String? {
        (try? decodeIfPresent(StremioString.self, forKey: key))?.value
    }

    /// Decodes an `Int` from a field an addon may send as a string or a number.
    nonisolated func stremioInt(_ key: Key) -> Int? {
        guard let raw = stremioString(key) else { return nil }
        return Int(raw)
    }
}

// MARK: - Manifest

nonisolated struct StremioManifest: Decodable {
    let id: String
    let version: String?
    let name: String
    let manifestDescription: String?
    let logo: String?
    let types: [String]
    let resources: [StremioResource]
    let catalogs: [StremioCatalog]
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case id, version, name, logo, types, resources, catalogs, idPrefixes
        case manifestDescription = "description"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        manifestDescription = try container.decodeIfPresent(String.self, forKey: .manifestDescription)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
        resources = try container.decodeIfPresent([StremioResource].self, forKey: .resources) ?? []
        catalogs = try container.decodeIfPresent([StremioCatalog].self, forKey: .catalogs) ?? []
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
    }

    /// Whether the addon declares a resource (its `resources` array mixes
    /// plain strings and `{name, types, idPrefixes}` objects).
    func supportsResource(_ name: String) -> Bool {
        resources.contains { $0.name == name }
    }

    /// Whether the addon declares it can serve the named resource for the
    /// given content type and meta-id prefix. A bare-string resource entry
    /// carries no scoping of its own, so the manifest-level
    /// `types`/`idPrefixes` fill in; an addon that scopes neither is taken at
    /// its word and matches anything.
    func supports(resource name: String, type: String, idPrefix: String) -> Bool {
        resources.contains { resource in
            guard resource.name == name else { return false }
            let resourceTypes = resource.types ?? types
            guard resourceTypes.isEmpty || resourceTypes.contains(type) else { return false }
            let prefixes = resource.idPrefixes ?? idPrefixes ?? []
            return prefixes.isEmpty || prefixes.contains(idPrefix)
        }
    }

    /// Whether the addon declares it can serve streams for the given content
    /// type and meta-id prefix.
    func supportsStreams(forType type: String, idPrefix: String) -> Bool {
        supports(resource: "stream", type: type, idPrefix: idPrefix)
    }
}

/// One entry of a manifest's `resources` array — either a bare string
/// (`"stream"`) or an object scoping the resource to specific types and id
/// prefixes.
nonisolated struct StremioResource: Decodable {
    let name: String
    let types: [String]?
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case name, types, idPrefixes
    }

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let plain = try? single.decode(String.self) {
            name = plain
            types = nil
            idPrefixes = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        types = try container.decodeIfPresent([String].self, forKey: .types)
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
    }
}

// MARK: - Catalogs

nonisolated struct StremioCatalog: Decodable {
    let type: String
    let id: String
    let name: String?
    let extra: [StremioCatalogExtra]?
    /// Legacy flat form of `extra`, still shipped by major addons (Cinemeta).
    let extraSupported: [String]?
    let extraRequired: [String]?

    /// Names of extras this catalog cannot be requested without (e.g. a
    /// search-only catalog requires `search`). Prefers the structured `extra`
    /// declaration and falls back to the legacy `extraRequired` list.
    var requiredExtraNames: [String] {
        if let extra {
            return extra.filter { $0.isRequired == true }.map(\.name)
        }
        return extraRequired ?? []
    }

    /// Whether the catalog can be requested plainly and shown as a browsable
    /// category. Catalogs with a required extra (search, a mandatory genre)
    /// only make sense with that extra supplied, so sync skips them.
    var isBrowsable: Bool {
        requiredExtraNames.isEmpty
    }

    /// Whether the catalog declares `skip` paging support.
    var supportsSkip: Bool {
        if let extra {
            return extra.contains { $0.name == "skip" }
        }
        return extraSupported?.contains("skip") ?? false
    }
}

nonisolated struct StremioCatalogExtra: Decodable {
    let name: String
    let isRequired: Bool?
    let options: [String]?
}

// MARK: - Meta

/// A catalog entry or full meta object. The protocol's meta preview is a
/// subset of the full meta, so one type decodes both.
nonisolated struct StremioMeta: Decodable {
    let id: String
    let type: String
    let name: String?
    let poster: String?
    let background: String?
    let logo: String?
    let metaDescription: String?
    /// Release year or range, e.g. `"2011"` or `"2011-2019"`. Occasionally a
    /// bare number in the wild.
    let releaseInfo: String?
    /// IMDb rating; documented as a number but shipped as a string by the
    /// canonical addons.
    let imdbRating: String?
    let runtime: String?
    let genres: [String]?
    let videos: [StremioVideo]?
    let behaviorHints: StremioMetaBehaviorHints?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, releaseInfo, imdbRating,
             runtime, genres, videos, behaviorHints
        case metaDescription = "description"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        metaDescription = try container.decodeIfPresent(String.self, forKey: .metaDescription)
        releaseInfo = container.stremioString(.releaseInfo)
        imdbRating = container.stremioString(.imdbRating)
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
        genres = try container.decodeIfPresent([String].self, forKey: .genres)
        videos = try container.decodeIfPresent([StremioVideo].self, forKey: .videos)
        behaviorHints = try container.decodeIfPresent(StremioMetaBehaviorHints.self, forKey: .behaviorHints)
    }

    /// The id to request streams for: metas can point playback at a specific
    /// video via `behaviorHints.defaultVideoId`.
    var streamRequestId: String {
        behaviorHints?.defaultVideoId ?? id
    }
}

nonisolated struct StremioMetaBehaviorHints: Decodable {
    let defaultVideoId: String?
}

/// One entry of a series meta's `videos` array — an episode. Addons use
/// `title` or `name` and `episode` or `number` interchangeably.
nonisolated struct StremioVideo: Decodable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let released: String?
    let thumbnail: String?
    let overview: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, season, episode, number, released, thumbnail,
             overview
        case videoDescription = "description"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.stremioString(.name)
        season = container.stremioInt(.season)
        episode = container.stremioInt(.episode) ?? container.stremioInt(.number)
        released = try container.decodeIfPresent(String.self, forKey: .released)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
            ?? container.stremioString(.videoDescription)
    }
}

// MARK: - Streams

nonisolated struct StremioStream: Decodable {
    /// Direct http(s) video URL — the only source kind Lume plays. Torrent
    /// (`infoHash`), YouTube (`ytId`) and browser (`externalUrl`) streams are
    /// filtered out at resolution time.
    let url: String?
    let ytId: String?
    let infoHash: String?
    let externalUrl: String?
    let name: String?
    let title: String?
    let streamDescription: String?
    let behaviorHints: StremioStreamBehaviorHints?

    enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, externalUrl, name, title, behaviorHints
        case streamDescription = "description"
    }

    /// The stream's direct http(s) playback URL, if it has one.
    var playableURL: URL? {
        guard infoHash == nil,
              let url, let resolved = URL(string: url),
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return resolved
    }

    /// HTTP headers the addon requires on the media request, from
    /// `behaviorHints.proxyHeaders` (MediaFusion's media proxy, header-guarded
    /// live-TV addons). An empty set collapses to `nil`.
    var requestHeaders: [String: String]? {
        guard let headers = behaviorHints?.proxyHeaders?.request, !headers.isEmpty else { return nil }
        return headers
    }
}

/// A stream's `behaviorHints`. `bingeGroup` ties together streams of the same
/// source/quality across a series so auto-advance can stay on the release the
/// viewer picked; `filename` and `videoSize` describe the underlying file.
nonisolated struct StremioStreamBehaviorHints: Decodable {
    let bingeGroup: String?
    let filename: String?
    /// File size in bytes; spec'd as a number but guarded against the string
    /// drift every other numeric field in the protocol exhibits.
    let videoSize: Int64?
    let notWebReady: Bool?
    let proxyHeaders: StremioProxyHeaders?

    enum CodingKeys: String, CodingKey {
        case bingeGroup, filename, videoSize, notWebReady, proxyHeaders
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bingeGroup = try? container.decodeIfPresent(String.self, forKey: .bingeGroup)
        filename = try? container.decodeIfPresent(String.self, forKey: .filename)
        if let bytes = try? container.decodeIfPresent(Int64.self, forKey: .videoSize) {
            videoSize = bytes
        } else if let raw = container.stremioString(.videoSize), let bytes = Int64(raw) {
            videoSize = bytes
        } else {
            videoSize = nil
        }
        notWebReady = try? container.decodeIfPresent(Bool.self, forKey: .notWebReady)
        proxyHeaders = try? container.decodeIfPresent(StremioProxyHeaders.self, forKey: .proxyHeaders)
    }
}

/// A stream's `proxyHeaders` behavior hint — HTTP headers the addon needs on
/// the media request (`request`) for the stream to play. Response headers are
/// ignored: they exist for browser-based clients, native demuxers can't act on
/// them.
nonisolated struct StremioProxyHeaders: Decodable {
    let request: [String: String]?

    enum CodingKeys: String, CodingKey {
        case request
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = (try? container.decodeIfPresent([String: StremioString].self, forKey: .request))?
            .compactMapValues(\.value)
    }
}

// MARK: - Subtitles

nonisolated struct StremioSubtitle: Decodable {
    let id: String
    let url: String
    let lang: String
}

// MARK: - Response envelopes

nonisolated struct StremioCatalogResponse: Decodable {
    let metas: [StremioMeta]

    enum CodingKeys: String, CodingKey {
        case metas
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metas = try container.decodeIfPresent([StremioMeta].self, forKey: .metas) ?? []
    }
}

nonisolated struct StremioMetaResponse: Decodable {
    let meta: StremioMeta
}

nonisolated struct StremioStreamResponse: Decodable {
    let streams: [StremioStream]

    enum CodingKeys: String, CodingKey {
        case streams
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decodeIfPresent([StremioStream].self, forKey: .streams) ?? []
    }
}

nonisolated struct StremioSubtitlesResponse: Decodable {
    let subtitles: [StremioSubtitle]

    enum CodingKeys: String, CodingKey {
        case subtitles
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = try container.decodeIfPresent([StremioSubtitle].self, forKey: .subtitles) ?? []
    }
}
