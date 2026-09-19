//
//  XMLTVDate.swift
//  Lume
//
//  Parses XMLTV programme timestamps (`YYYYMMDDHHMMSS ±HHMM`).
//
//  `DateFormatter.date(from:)` runs full ICU locale parsing on every call. On a
//  large XMLTV guide (two timestamps per programme, tens of thousands of
//  programmes) that dominates EPG ingest and froze the UI for ~9s right after a
//  playlist sync. The fast path parses the fixed-width canonical timestamp by
//  hand; anything non-standard falls back to the formatter, so results are
//  byte-identical to the previous behaviour.
//

import Foundation

enum XMLTVDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ dateString: String?) -> Date? {
        guard let dateString, !dateString.isEmpty else { return nil }
        return fastParse(dateString) ?? formatter.date(from: dateString)
    }

    /// Fast path for the canonical XMLTV timestamp `YYYYMMDDHHMMSS ±HHMM`
    /// (e.g. `20240625203000 +0000`) and its offset-less forms
    /// `YYYYMMDDHHMMSS` (14 digits) and `YYYYMMDDHHMM` (12 digits). The XMLTV
    /// DTD says "if no explicit timezone is given, UTC is assumed", so the
    /// offset-less shapes parse as UTC here rather than falling through to the
    /// ~600× slower `DateFormatter` (which rejects them, silently dropping the
    /// programme). Returns nil for any other shape so the formatter handles it.
    private static func fastParse(_ string: String) -> Date? {
        let bytes = Array(string.utf8)

        // Seconds and the UTC offset are the only fields that vary by shape;
        // the leading `YYYYMMDDHHMM` is common to all three.
        guard let tail = secondAndOffset(bytes) else { return nil }

        guard let year = digits(bytes, 0, 4), let month = digits(bytes, 4, 2), let day = digits(bytes, 6, 2),
              let hour = digits(bytes, 8, 2), let minute = digits(bytes, 10, 2),
              month >= 1, month <= 12, day >= 1, day <= 31,
              hour < 24, minute < 60, tail.second < 60
        else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let epoch = days * 86400 + hour * 3600 + minute * 60 + tail.second - tail.offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Reads `count` ASCII digits from `bytes` starting at `start`, or nil if any
    /// byte in the range is not `0`–`9`.
    private static func digits(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        var value = 0
        for offset in start ..< (start + count) {
            let byte = bytes[offset]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    /// Parses the seconds field and UTC offset for the three accepted shapes,
    /// returning nil for any other byte length or malformed offset.
    private static func secondAndOffset(_ bytes: [UInt8]) -> (second: Int, offsetSeconds: Int)? {
        switch bytes.count {
        case 20:
            // 14 date digits + space + sign + 4 offset digits = 20 bytes exactly.
            guard let sec = digits(bytes, 12, 2), bytes[14] == 0x20 else { return nil }
            let sign: Int
            switch bytes[15] {
            case 0x2B: sign = 1 // '+'
            case 0x2D: sign = -1 // '-'
            default: return nil
            }
            guard let offsetHours = digits(bytes, 16, 2), let offsetMinutes = digits(bytes, 18, 2) else { return nil }
            return (sec, sign * (offsetHours * 3600 + offsetMinutes * 60))
        case 14:
            guard let sec = digits(bytes, 12, 2) else { return nil }
            return (sec, 0)
        case 12:
            return (0, 0)
        default:
            return nil
        }
    }

    /// Days from 1970-01-01 to a proleptic-Gregorian date (Howard Hinnant's
    /// `days_from_civil`). Avoids `Calendar`, which is itself locale-aware and
    /// far slower than this arithmetic.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
