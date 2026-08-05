//
//  StalkerDTOs.swift
//  Lume
//
//  Decodable models for the Stalker (Ministra) portal API. Every response is
//  wrapped in a top-level `{"js": …}` envelope. The portal is loose about types
//  — ids, counts and flags come back as either JSON numbers or quoted strings —
//  so the DTOs decode those fields flexibly.
//

import Foundation

// MARK: - Flexible decoding

/// A value the portal sends as either a string or a number; decodes to `String`.
nonisolated struct StalkerString: Decodable, Equatable {
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
    /// Decodes a `String` from a field the portal may send as a string or a
    /// number, returning `nil` when the key is absent or null.
    /// `nonisolated` so the DTOs' `nonisolated init(from:)` can call it without
    /// the project-wide default MainActor isolation making the call async.
    nonisolated func stalkerString(_ key: Key) -> String? {
        (try? decodeIfPresent(StalkerString.self, forKey: key))?.value
    }

    /// Decodes an `Int` from a field the portal may send as a string or a number.
    nonisolated func stalkerInt(_ key: Key) -> Int? {
        guard let raw = stalkerString(key) else { return nil }
        return Int(raw)
    }
}

// MARK: - Envelopes

/// The `{"js": T}` wrapper every portal response carries. The field name `js`
/// is the portal's own key.
nonisolated struct StalkerEnvelope<T: Decodable>: Decodable {
    // swiftlint:disable:next identifier_name
    let js: T
}

/// A paginated `js` payload: `{ "total_items": …, "max_page_items": …, "data": [...] }`.
/// `get_all_channels` reuses this shape with only `data` populated.
nonisolated struct StalkerPage<Item: Decodable>: Decodable {
    let data: [Item]
    let totalItems: Int?
    let maxPageItems: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decode([Item].self, forKey: .data)) ?? []
        totalItems = container.stalkerInt(.totalItems)
        maxPageItems = container.stalkerInt(.maxPageItems)
    }

    enum CodingKeys: String, CodingKey {
        case data
        case totalItems = "total_items"
        case maxPageItems = "max_page_items"
    }
}

// MARK: - Handshake / profile

nonisolated struct StalkerHandshake: Decodable {
    let token: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = container.stalkerString(.token)
    }

    enum CodingKeys: String, CodingKey {
        case token
    }
}

/// Subset of `get_profile` the app surfaces in the playlist's account section.
nonisolated struct StalkerProfile: Decodable {
    let status: String?
    let expDate: String?
    let phone: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.stalkerString(.status)
        expDate = container.stalkerString(.expDate)
        phone = container.stalkerString(.phone)
    }

    enum CodingKeys: String, CodingKey {
        case status
        case expDate = "exp_date"
        case phone
    }
}

// MARK: - Genres / categories

/// A live-TV genre (`itv get_genres`) or a VOD/series category
/// (`get_categories`). Both share `{ id, title }`.
nonisolated struct StalkerCategory: Decodable {
    let id: String
    let title: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.stalkerString(.id) ?? ""
        title = container.stalkerString(.title) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
    }
}

// MARK: - Live channel

nonisolated struct StalkerChannel: Decodable {
    let id: String?
    let name: String?
    let number: Int?
    /// The play command passed to `create_link` at playback time.
    let cmd: String?
    let logo: String?
    /// The genre id this channel belongs to (`tv_genre_id`).
    let genreId: String?
    /// XMLTV channel id used to match this channel to an attached EPG source.
    let xmltvId: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.stalkerString(.id)
        name = container.stalkerString(.name)
        number = container.stalkerInt(.number)
        cmd = container.stalkerString(.cmd)
        logo = container.stalkerString(.logo)
        genreId = container.stalkerString(.genreId)
        xmltvId = container.stalkerString(.xmltvId)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, number, cmd, logo
        case genreId = "tv_genre_id"
        case xmltvId = "xmltv_id"
    }
}

// MARK: - VOD / series item

/// A VOD title (`vod get_ordered_list`) or a series (`series get_ordered_list`).
/// They share the same shape; `seriesNumbers` is populated only for series and
/// lists the available episode numbers.
nonisolated struct StalkerVODItem: Decodable {
    let id: String?
    let name: String?
    let cmd: String?
    let screenshot: String?
    let year: String?
    let description: String?
    let rating: String?
    let genreId: String?
    let categoryId: String?
    /// When the portal added this title (`"YYYY-MM-DD HH:MM:SS"`, lexically
    /// sortable). The default sync fetches newest-first and orders the
    /// Recently Added rail by it.
    let added: String?
    /// Episode numbers available for a series item (`series` field). Empty for
    /// plain VOD.
    let seriesNumbers: [Int]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.stalkerString(.id)
        name = container.stalkerString(.name)
        cmd = container.stalkerString(.cmd)
        screenshot = container.stalkerString(.screenshot)
        year = container.stalkerString(.year)
        description = container.stalkerString(.description)
        rating = container.stalkerString(.rating)
        genreId = container.stalkerString(.genreId)
        categoryId = container.stalkerString(.categoryId)
        added = container.stalkerString(.added)
        seriesNumbers = (try? container.decodeIfPresent([Int].self, forKey: .seriesNumbers)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, name, cmd, year, description, rating, added
        case screenshot = "screenshot_uri"
        case genreId = "tv_genre_id"
        case categoryId = "category_id"
        case seriesNumbers = "series"
    }
}

// MARK: - create_link

nonisolated struct StalkerCreateLink: Decodable {
    let cmd: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cmd = container.stalkerString(.cmd)
    }

    enum CodingKeys: String, CodingKey {
        case cmd
    }
}
