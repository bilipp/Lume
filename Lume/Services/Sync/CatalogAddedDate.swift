//
//  CatalogAddedDate.swift
//  Lume
//
//  The one stored format for `Movie.added`, `LiveStream.added` and
//  `Series.lastModified`: exactly ten zero-padded digits of Unix seconds.
//  "Recently Added" and the newest-first sorts order these columns with a
//  binary (`.lexical`) comparison so SQLite can walk their index, which only
//  matches chronological order while every source writes the same fixed-width
//  digits. Xtream ships Unix seconds, Stalker `YYYY-MM-DD HH:MM:SS`, Jellyfin
//  and Emby ISO-8601, Plex an integer; a date string would sort above every
//  Unix value.
//
//  Parsed by hand: this runs for every row of every sync, twice (provider value
//  and stored value), so no formatter is built or shared.
//

import Foundation

nonisolated enum CatalogAddedDate {
    static let width = 10
    private static let maxSeconds = 9_999_999_999

    /// The canonical form of a provider or stored timestamp, or nil when it
    /// can't be read. Accepts Unix seconds (13-digit milliseconds too),
    /// `YYYY-MM-DD`, `YYYY-MM-DD HH:MM[:SS]` and ISO-8601 with an optional
    /// fraction and zone; a stamp without a zone is read as UTC.
    static func unixString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bytes = raw.utf8
        if bytes.count == width, bytes.allSatisfy(isDigit) { return raw }
        guard let seconds = unixSeconds(raw) else { return nil }
        return unixString(seconds: seconds)
    }

    /// Stores `raw`'s canonical form in `field`, assigning only when the two
    /// differ canonically: SwiftData marks a row dirty on assignment, and a row
    /// stored in an older format must not be rewritten by every sync.
    static func assign<Model: AnyObject>(
        _ raw: String?, to field: ReferenceWritableKeyPath<Model, String?>, of model: Model
    ) {
        let canonical = unixString(raw)
        if unixString(model[keyPath: field]) != canonical { model[keyPath: field] = canonical }
    }

    static func unixString(seconds: Int) -> String? {
        guard seconds >= 0, seconds <= maxSeconds else { return nil }
        let digits = String(seconds)
        return String(repeating: "0", count: width - digits.utf8.count) + digits
    }

    /// Whether two stored stamps name the same instant, whatever format each
    /// was written in. Unreadable values only match themselves.
    static func sameInstant(_ lhs: String?, _ rhs: String?) -> Bool {
        if lhs == rhs { return true }
        guard let normalised = unixString(lhs) else { return false }
        return normalised == unixString(rhs)
    }

    static func unixSeconds(_ raw: String) -> Int? {
        var copy = raw
        return copy.withUTF8 { parse($0) }
    }

    // MARK: - Parsing

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func parse(_ buffer: UnsafeBufferPointer<UInt8>) -> Int? {
        var start = 0
        var end = buffer.count
        while start < end, isSpace(buffer[start]) {
            start += 1
        }
        while end > start, isSpace(buffer[end - 1]) {
            end -= 1
        }
        guard start < end else { return nil }

        var cursor = Cursor(buffer: buffer, index: start, end: end)
        if let seconds = cursor.wholeNumber() {
            return seconds
        }
        return cursor.dateTime()
    }

    private struct Cursor {
        let buffer: UnsafeBufferPointer<UInt8>
        var index: Int
        let end: Int

        var atEnd: Bool {
            index >= end
        }

        func peek() -> UInt8? {
            index < end ? buffer[index] : nil
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard peek() == byte else { return false }
            index += 1
            return true
        }

        mutating func digits(_ count: Int) -> Int? {
            guard end - index >= count else { return nil }
            var value = 0
            for offset in 0 ..< count {
                let byte = buffer[index + offset]
                guard CatalogAddedDate.isDigit(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += count
            return value
        }

        /// Unix seconds when the whole input is digits; nil leaves the cursor
        /// untouched for the date parser.
        func wholeNumber() -> Int? {
            let count = end - index
            guard count <= 13 else { return nil }
            var value = 0
            for offset in index ..< end {
                let byte = buffer[offset]
                guard CatalogAddedDate.isDigit(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            switch count {
            case 1 ... CatalogAddedDate.width: return value
            case 13: return value / 1000
            default: return nil
            }
        }

        mutating func dateTime() -> Int? {
            guard let year = digits(4), consume(0x2D),
                  let month = digits(2), consume(0x2D),
                  let day = digits(2),
                  (1 ... 12).contains(month),
                  (1 ... CatalogAddedDate.daysIn(month: month, year: year)).contains(day)
            else { return nil }

            var secondsOfDay = 0
            if !atEnd {
                guard consume(0x20) || consume(0x54) || consume(0x74),
                      let time = timeOfDay()
                else { return nil }
                secondsOfDay = time
            }
            guard let offset = zoneOffset(), atEnd else { return nil }

            let days = CivilDate.daysFromCivil(year: year, month: month, day: day)
            let seconds = days * 86400 + secondsOfDay - offset
            guard seconds >= 0, seconds <= CatalogAddedDate.maxSeconds else { return nil }
            return seconds
        }

        private mutating func timeOfDay() -> Int? {
            guard let hour = digits(2), consume(0x3A), let minute = digits(2),
                  hour <= 23, minute <= 59
            else { return nil }
            var second = 0
            if consume(0x3A) {
                guard let parsed = digits(2), parsed <= 60 else { return nil }
                second = parsed
                if consume(0x2E) || consume(0x2C) {
                    guard let byte = peek(), CatalogAddedDate.isDigit(byte) else { return nil }
                    while let byte = peek(), CatalogAddedDate.isDigit(byte) {
                        index += 1
                    }
                }
            }
            return hour * 3600 + minute * 60 + second
        }

        /// The zone's offset east of UTC in seconds; 0 when there is none.
        private mutating func zoneOffset() -> Int? {
            while let byte = peek(), CatalogAddedDate.isSpace(byte) {
                index += 1
            }
            if atEnd { return 0 }
            if consume(0x5A) || consume(0x7A) { return 0 }
            let sign: Int
            if consume(0x2B) {
                sign = 1
            } else if consume(0x2D) {
                sign = -1
            } else {
                return nil
            }
            guard let hours = digits(2), hours <= 23 else { return nil }
            var minutes = 0
            if !atEnd {
                _ = consume(0x3A)
                guard let parsed = digits(2), parsed <= 59 else { return nil }
                minutes = parsed
            }
            return sign * (hours * 3600 + minutes * 60)
        }
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}
