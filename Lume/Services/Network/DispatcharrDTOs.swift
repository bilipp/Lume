//
//  DispatcharrDTOs.swift
//  Lume
//
//  Wire shapes of the Dispatcharr REST API (verified against 0.33.0, see
//  `LumeTests/Fixtures/Dispatcharr/README.md`). Decoding is lenient: a
//  recording's `custom_properties` is free-form JSON that rules, the web UI and
//  the recorder all write into, so one odd field must never fail a list.
//

import Foundation

nonisolated struct DispatcharrVersion: Decodable, Hashable {
    var version: String

    private enum CodingKeys: String, CodingKey {
        case version
    }

    init(version: String) {
        self.version = version
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.lenientString(forKey: .version) ?? ""
    }
}

/// What the signed-in account may do with recordings.
nonisolated enum DispatcharrDVRAccess: String, Hashable {
    case none
    case view
    case manage
}

/// `GET /api/accounts/users/me/`. The body also carries the account's API key
/// and XC password in plain text; neither is decoded, so neither can leak from
/// here.
nonisolated struct DispatcharrUser: Decodable, Hashable {
    static let adminLevel = 10

    var id: Int
    var username: String
    /// `0` streamer, `1` standard, `10` admin.
    var userLevel: Int
    /// `custom_properties.dvr_access` as the server stores it.
    var dvrAccessSetting: String?

    private enum CodingKeys: String, CodingKey {
        case id, username
        case userLevel = "user_level"
        case customProperties = "custom_properties"
    }

    private enum PropertyKeys: String, CodingKey {
        case dvrAccess = "dvr_access"
    }

    init(id: Int, username: String, userLevel: Int, dvrAccessSetting: String? = nil) {
        self.id = id
        self.username = username
        self.userLevel = userLevel
        self.dvrAccessSetting = dvrAccessSetting
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenientInt(forKey: .id) ?? 0
        username = container.lenientString(forKey: .username) ?? ""
        userLevel = container.lenientInt(forKey: .userLevel) ?? 0
        let properties = try? container.nestedContainer(keyedBy: PropertyKeys.self, forKey: .customProperties)
        dvrAccessSetting = properties?.lenientString(forKey: .dvrAccess)
    }

    /// Mirrors the server's `dvr_access.py`: admins always manage, streamers
    /// never see recordings, and a standard user without a valid setting views.
    var dvrAccess: DispatcharrDVRAccess {
        if userLevel >= Self.adminLevel { return .manage }
        if userLevel <= 0 { return .none }
        return dvrAccessSetting.flatMap(DispatcharrDVRAccess.init(rawValue:)) ?? .view
    }
}

nonisolated struct DispatcharrChannel: Decodable, Hashable {
    var id: Int
    var uuid: UUID?
    var name: String
    var channelNumber: Double?
    var logoID: Int?

    private enum CodingKeys: String, CodingKey {
        case id, uuid, name
        case effectiveName = "effective_name"
        case channelNumber = "channel_number"
        case effectiveChannelNumber = "effective_channel_number"
        case logoID = "logo_id"
        case effectiveLogoID = "effective_logo_id"
    }

    init(id: Int, uuid: UUID? = nil, name: String, channelNumber: Double? = nil, logoID: Int? = nil) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.channelNumber = channelNumber
        self.logoID = logoID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lenientInt(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "id"))
        }
        self.id = id
        uuid = container.lenientString(forKey: .uuid).flatMap(UUID.init(uuidString:))
        name = container.lenientString(forKey: .effectiveName) ?? container.lenientString(forKey: .name) ?? ""
        channelNumber = container.lenientDouble(forKey: .effectiveChannelNumber)
            ?? container.lenientDouble(forKey: .channelNumber)
        logoID = container.lenientInt(forKey: .effectiveLogoID) ?? container.lenientInt(forKey: .logoID)
    }
}

/// The programme a recording was made for. Dispatcharr pads the top-level
/// times server-side; these stay the unpadded EPG times.
nonisolated struct DispatcharrProgram: Codable, Hashable {
    var title: String?
    var subtitle: String?
    var description: String?
    var start: Date?
    var end: Date?

    private enum CodingKeys: String, CodingKey {
        case title, description
        case subtitle = "sub_title"
        case start = "start_time"
        case end = "end_time"
    }

    init(title: String?, subtitle: String? = nil, description: String? = nil, start: Date?, end: Date?) {
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.start = start
        self.end = end
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timeZone = decoder.dispatcharrNaiveTimeZone
        title = container.lenientString(forKey: .title)
        subtitle = container.lenientString(forKey: .subtitle)
        description = container.lenientString(forKey: .description)
        start = container.lenientString(forKey: .start).flatMap { DispatcharrDate.parse($0, naiveTimeZone: timeZone) }
        end = container.lenientString(forKey: .end).flatMap { DispatcharrDate.parse($0, naiveTimeZone: timeZone) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(start.map(DispatcharrDate.format), forKey: .start)
        try container.encodeIfPresent(end.map(DispatcharrDate.format), forKey: .end)
    }
}

/// The recorder's bookkeeping inside a recording's `custom_properties`.
nonisolated struct DispatcharrRecordingProperties: Hashable {
    /// `nil` until the recording task starts.
    var status: String?
    var sourceRef: String?
    /// The idempotency key of the Lume action that created the recording.
    var requestID: String?
    var program: DispatcharrProgram?
    var startedAt: Date?
    var endedAt: Date?
    var stoppedAt: Date?
    var interruptedReason: String?
    var error: String?
    var bytesWritten: Int64?
    var remuxSuccess: Bool?
    var posterLogoID: Int?
    var posterURL: URL?

    init(
        status: String? = nil,
        sourceRef: String? = nil,
        requestID: String? = nil,
        program: DispatcharrProgram? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        stoppedAt: Date? = nil,
        interruptedReason: String? = nil,
        error: String? = nil,
        bytesWritten: Int64? = nil,
        remuxSuccess: Bool? = nil,
        posterLogoID: Int? = nil,
        posterURL: URL? = nil
    ) {
        self.status = status
        self.sourceRef = sourceRef
        self.requestID = requestID
        self.program = program
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stoppedAt = stoppedAt
        self.interruptedReason = interruptedReason
        self.error = error
        self.bytesWritten = bytesWritten
        self.remuxSuccess = remuxSuccess
        self.posterLogoID = posterLogoID
        self.posterURL = posterURL
    }
}

nonisolated extension DispatcharrRecordingProperties: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status, program, error
        case sourceRef = "lume_source_ref"
        case requestID = "lume_request_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case stoppedAt = "stopped_at"
        case interruptedReason = "interrupted_reason"
        case bytesWritten = "bytes_written"
        case remuxSuccess = "remux_success"
        case posterLogoID = "poster_logo_id"
        case posterURL = "poster_url"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timeZone = decoder.dispatcharrNaiveTimeZone
        func date(_ key: CodingKeys) -> Date? {
            container.lenientString(forKey: key).flatMap { DispatcharrDate.parse($0, naiveTimeZone: timeZone) }
        }
        status = container.lenientString(forKey: .status)
        sourceRef = container.lenientString(forKey: .sourceRef)
        requestID = container.lenientString(forKey: .requestID)
        program = try? container.decodeIfPresent(DispatcharrProgram.self, forKey: .program)
        startedAt = date(.startedAt)
        endedAt = date(.endedAt)
        stoppedAt = date(.stoppedAt)
        interruptedReason = container.lenientString(forKey: .interruptedReason)
        error = container.lenientString(forKey: .error)
        bytesWritten = container.lenientDouble(forKey: .bytesWritten).map { Int64($0) }
        remuxSuccess = try? container.decodeIfPresent(Bool.self, forKey: .remuxSuccess)
        posterLogoID = container.lenientInt(forKey: .posterLogoID)
        posterURL = container.lenientString(forKey: .posterURL).flatMap(URL.init(string:))
    }
}

nonisolated struct DispatcharrRecording: Decodable, Hashable, Identifiable {
    var id: Int
    var channelID: Int?
    /// Padded start; the programme's own times are in `properties.program`.
    var start: Date
    var end: Date
    var properties: DispatcharrRecordingProperties

    private enum CodingKeys: String, CodingKey {
        case id, channel
        case start = "start_time"
        case end = "end_time"
        case properties = "custom_properties"
    }

    init(id: Int, channelID: Int?, start: Date, end: Date, properties: DispatcharrRecordingProperties = .init()) {
        self.id = id
        self.channelID = channelID
        self.start = start
        self.end = end
        self.properties = properties
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timeZone = decoder.dispatcharrNaiveTimeZone
        guard let id = container.lenientInt(forKey: .id),
              let start = container.lenientString(forKey: .start)
              .flatMap({ DispatcharrDate.parse($0, naiveTimeZone: timeZone) }),
              let end = container.lenientString(forKey: .end)
              .flatMap({ DispatcharrDate.parse($0, naiveTimeZone: timeZone) })
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "recording without id or times"
            ))
        }
        self.id = id
        self.start = start
        self.end = end
        channelID = container.lenientInt(forKey: .channel)
        properties = (try? container.decodeIfPresent(DispatcharrRecordingProperties.self, forKey: .properties)) ?? .init()
    }
}

/// `POST /api/channels/recordings/`. With a `program`, the server applies its
/// own pre/post padding to `start`/`end`; Lume never pads Dispatcharr.
nonisolated struct DispatcharrRecordingCreate: Encodable, Hashable {
    var channelID: Int
    var start: Date
    var end: Date
    var sourceRef: String?
    var requestID: String?
    var program: DispatcharrProgram?

    private enum CodingKeys: String, CodingKey {
        case channel
        case start = "start_time"
        case end = "end_time"
        case customProperties = "custom_properties"
    }

    private enum PropertyKeys: String, CodingKey {
        case sourceRef = "lume_source_ref"
        case requestID = "lume_request_id"
        case program
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channelID, forKey: .channel)
        try container.encode(DispatcharrDate.format(start), forKey: .start)
        try container.encode(DispatcharrDate.format(end), forKey: .end)
        var properties = container.nestedContainer(keyedBy: PropertyKeys.self, forKey: .customProperties)
        try properties.encodeIfPresent(sourceRef, forKey: .sourceRef)
        try properties.encodeIfPresent(requestID, forKey: .requestID)
        try properties.encodeIfPresent(program, forKey: .program)
    }
}

/// A bare JSON array, or a DRF page when the server paginates anyway.
nonisolated struct DispatcharrList<Element: Decodable>: Decodable {
    var items: [Element]

    private enum CodingKeys: String, CodingKey {
        case results
    }

    init(from decoder: any Decoder) throws {
        let elements: [LenientElement] = if let array = try? decoder.singleValueContainer().decode([LenientElement].self) {
            array
        } else {
            try decoder.container(keyedBy: CodingKeys.self).decode([LenientElement].self, forKey: .results)
        }
        items = elements.compactMap(\.value)
    }

    /// One malformed row is dropped instead of failing the whole list.
    private struct LenientElement: Decodable {
        let value: Element?

        init(from decoder: any Decoder) throws {
            value = try? Element(from: decoder)
        }
    }
}

nonisolated struct DispatcharrTokenPair: Decodable, Hashable {
    var access: String
    /// Absent from a refresh response: Dispatcharr doesn't rotate refresh tokens.
    var refresh: String?
}

// MARK: - Dates

/// Dispatcharr writes aware ISO-8601 for the scheduled times but naive
/// `YYYY-MM-DD HH:MM:SS.ffffff` (`str(datetime.now())`) for the recorder's own
/// stamps. A naive stamp is read in the server's time zone, UTC in 0.33.0.
nonisolated enum DispatcharrDate {
    static func format(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func parse(_ raw: String, naiveTimeZone: TimeZone) -> Date? {
        var scanner = StampScanner(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let year = scanner.digits(4), scanner.skip("-"), let month = scanner.digits(2), scanner.skip("-"),
              let day = scanner.digits(2), scanner.skip("T") || scanner.skip(" ") || scanner.skip("t"),
              let hour = scanner.digits(2), scanner.skip(":"), let minute = scanner.digits(2),
              let second = scanner.skip(":") ? scanner.digits(2) : 0
        else { return nil }
        let fraction = scanner.skip(".") ? scanner.fraction() : 0
        guard let timeZone = scanner.zone(default: naiveTimeZone), scanner.isAtEnd,
              (1 ... 12).contains(month), (1 ... 31).contains(day),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute), (0 ... 60).contains(second)
        else { return nil }

        let wallClock = TimeInterval(
            daysFromCivil(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second
        )
        let firstOffset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wallClock))
        let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wallClock - TimeInterval(firstOffset)))
        return Date(timeIntervalSince1970: wallClock - TimeInterval(offset) + fraction)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Hinnant's
    /// `days_from_civil`); an out-of-range day rolls over like `Calendar` does.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private struct StampScanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ string: String) {
            bytes = Array(string.utf8)
        }

        var isAtEnd: Bool {
            index == bytes.count
        }

        private var currentDigit: Int? {
            guard index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") else { return nil }
            return Int(bytes[index] - UInt8(ascii: "0"))
        }

        mutating func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0 ..< count {
                guard let digit = currentDigit else { return nil }
                value = value * 10 + digit
                index += 1
            }
            return value
        }

        mutating func skip(_ character: Character) -> Bool {
            guard index < bytes.count, bytes[index] == character.asciiValue else { return false }
            index += 1
            return true
        }

        mutating func fraction() -> Double {
            var value = 0.0
            var scale = 0.1
            while let digit = currentDigit {
                value += Double(digit) * scale
                scale /= 10
                index += 1
            }
            return value
        }

        /// `Z`, `±HH:MM` or `±HHMM`; `fallback` when the stamp has none, `nil`
        /// for a malformed offset.
        mutating func zone(default fallback: TimeZone) -> TimeZone? {
            if skip("Z") || skip("z") { return .gmt }
            let sign: Int
            if skip("+") {
                sign = 1
            } else if skip("-") {
                sign = -1
            } else {
                return fallback
            }
            guard let hours = digits(2) else { return nil }
            _ = skip(":")
            let minutes = digits(2) ?? 0
            return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
        }
    }
}

nonisolated extension CodingUserInfoKey {
    static let dispatcharrNaiveTimeZone = CodingUserInfoKey(rawValue: "lume.dispatcharr.naiveTimeZone")!
}

nonisolated extension Decoder {
    var dispatcharrNaiveTimeZone: TimeZone {
        userInfo[.dispatcharrNaiveTimeZone] as? TimeZone ?? .gmt
    }
}
