//
//  M3UParser.swift
//  Lume
//
//  Streaming parser for m3u / m3u8 playlists (the "extended m3u" IPTV dialect:
//  #EXTINF lines with tvg-* attributes followed by a stream URL).
//
//  Like XMLTVParser, it never holds the whole file in memory: the file is read
//  in fixed-size chunks, split into lines, and parsed entries are handed to the
//  caller in batches — so a multi-hundred-megabyte provider export parses with
//  flat memory.
//

import Foundation

// MARK: - Parsed values

/// The `#EXTM3U` header line's attributes.
nonisolated struct M3UHeader {
    /// XMLTV guide URL from `url-tvg` / `x-tvg-url`, when the playlist carries one.
    var epgURL: String?
}

/// One playlist entry: an `#EXTINF` line plus the stream URL that follows it.
nonisolated struct M3UEntry {
    var name: String
    var url: String
    var tvgId: String?
    var logo: String?
    var group: String?
    /// The provider's explicit `type="…"` attribute (e.g. `video` for VOD),
    /// when present. Some providers serve live and on-demand through identical
    /// URLs and only this attribute distinguishes them.
    var type: String?
    /// Raw catch-up dialect (`catchup-type` / `catchup`), kept verbatim —
    /// `CatchupType.parse` folds in the wild spellings.
    var catchupTypeRaw: String?
    /// Archive depth in days, when the channel declares one. `nil` means the
    /// channel declares catch-up without a depth.
    var catchupDays: Int?
    /// `catchup-source` template, kept verbatim: it carries `{utc}`-style
    /// placeholders that must be expanded at play time, never at import time.
    var catchupSource: String?
}

// MARK: - Parser

nonisolated enum M3UParser {
    /// Bytes read from disk per chunk. Large enough to amortize I/O, small
    /// enough to keep memory flat.
    private static let chunkSize = 512 * 1024

    /// Parses an m3u file from disk, calling `onBatch` for every `batchSize`
    /// entries (and once more with the remainder). Returns the total entry count.
    ///
    /// `onHeader` fires at most once, as soon as the `#EXTM3U` line is seen —
    /// before any batch — so callers can pick up the embedded EPG URL.
    @discardableResult
    static func parse(
        fileURL: URL,
        batchSize: Int = 2000,
        onHeader: ((M3UHeader) -> Void)? = nil,
        onBatch: ([M3UEntry]) -> Void
    ) throws -> Int {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var state = ParseState()
        var batch: [M3UEntry] = []
        batch.reserveCapacity(batchSize)
        var totalCount = 0

        var carry = Data()
        var reachedEOF = false
        while !reachedEOF {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty {
                carry.append(chunk)
            } else {
                reachedEOF = true
            }

            // Split everything up to the last newline into lines; the tail
            // (a partial line) stays in `carry` for the next chunk. At EOF the
            // whole remainder is one final line.
            let processable: Data
            if reachedEOF {
                processable = carry
                carry = Data()
            } else if let lastNewline = carry.lastIndex(of: UInt8(ascii: "\n")) {
                processable = carry.subdata(in: carry.startIndex ..< lastNewline)
                carry = carry.subdata(in: carry.index(after: lastNewline) ..< carry.endIndex)
            } else {
                continue
            }

            for lineData in processable.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                // Latin-1 fallback: it never fails, so a stray non-UTF-8 line
                // (older provider exports) degrades to mojibake instead of
                // dropping the entry.
                let raw = String(bytes: lineData, encoding: .utf8)
                    ?? String(bytes: lineData, encoding: .isoLatin1)
                guard let line = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }

                if let entry = state.consume(line: line, onHeader: onHeader) {
                    batch.append(entry)
                    totalCount += 1
                    if batch.count >= batchSize {
                        onBatch(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        if !batch.isEmpty {
            onBatch(batch)
        }
        return totalCount
    }

    // MARK: - Line state machine

    /// Carries the pending `#EXTINF` metadata between lines until the stream
    /// URL arrives.
    private nonisolated struct ParseState {
        var pendingInfo: ExtInf?
        /// Group from a standalone `#EXTGRP:` directive (some providers emit it
        /// instead of, or in addition to, `group-title`).
        var pendingGroup: String?
        var headerDelivered = false

        mutating func consume(line: String, onHeader: ((M3UHeader) -> Void)?) -> M3UEntry? {
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    pendingInfo = M3UParser.parseExtInf(line)
                } else if line.hasPrefix("#EXTGRP:") {
                    pendingGroup = String(line.dropFirst("#EXTGRP:".count))
                        .trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("#EXTM3U"), !headerDelivered {
                    headerDelivered = true
                    onHeader?(M3UParser.parseHeader(line))
                }
                // Anything else (#EXTVLCOPT, #KODIPROP, comments…) is skipped.
                return nil
            }

            // A non-comment line is the stream URL for the pending entry.
            defer {
                pendingInfo = nil
                pendingGroup = nil
            }

            guard let info = pendingInfo else {
                // Plain (non-extended) m3u: a bare URL with no metadata.
                guard looksLikeURL(line) else { return nil }
                let fallbackName = URL(string: line)?.deletingPathExtension().lastPathComponent ?? line
                return M3UEntry(
                    name: fallbackName,
                    url: line,
                    tvgId: nil,
                    logo: nil,
                    group: pendingGroup,
                    type: nil,
                    catchupTypeRaw: nil,
                    catchupDays: nil,
                    catchupSource: nil
                )
            }

            let name = info.name.isEmpty ? (info.tvgName ?? line) : info.name
            return M3UEntry(
                name: name,
                url: line,
                tvgId: info.tvgId,
                logo: info.logo,
                group: info.group ?? pendingGroup,
                type: info.type,
                catchupTypeRaw: info.catchupTypeRaw,
                catchupDays: info.catchupDays,
                catchupSource: info.catchupSource
            )
        }

        private func looksLikeURL(_ line: String) -> Bool {
            line.contains("://")
        }
    }

    // MARK: - #EXTINF parsing

    nonisolated struct ExtInf {
        var name: String
        var tvgId: String?
        var tvgName: String?
        var logo: String?
        var group: String?
        var type: String?
        var catchupTypeRaw: String?
        var catchupDays: Int?
        var catchupSource: String?
    }

    /// Parses `#EXTINF:-1 tvg-id="..." tvg-logo="..." group-title="...",Name`.
    ///
    /// Attribute values may contain commas, so the display name starts at the
    /// first comma reached *outside* a quoted value — where the attribute scan
    /// stops.
    static func parseExtInf(_ line: String) -> ExtInf {
        let body = String(line.dropFirst("#EXTINF:".count))

        let (attributes, stop) = scanAttributes(body)

        // Name: after the comma the attribute scan stopped on.
        var name = ""
        if let comma = body[stop...].firstIndex(of: ",") {
            name = String(body[body.index(after: comma)...])
                .trimmingCharacters(in: .whitespaces)
        }

        // `tvg-rec` is an enable flag, not a dialect: only its truthy spellings
        // stand in for a missing `catchup`/`catchup-type`, and such a flag
        // carries no day count.
        let rec = nonEmpty(attributes["tvg-rec"])
        let recIsFlag = rec.map(CatchupType.isEnableFlag) ?? false
        let recDays = recIsFlag ? nil : rec.flatMap { Int($0) }

        return ExtInf(
            name: name,
            tvgId: nonEmpty(attributes["tvg-id"]),
            tvgName: nonEmpty(attributes["tvg-name"]),
            logo: nonEmpty(attributes["tvg-logo"]),
            group: nonEmpty(attributes["group-title"]),
            type: nonEmpty(attributes["type"]),
            catchupTypeRaw: nonEmpty(attributes["catchup-type"]) ?? nonEmpty(attributes["catchup"]) ?? (recIsFlag ? rec : nil),
            catchupDays: positive(attributes["catchup-days"].flatMap { Int($0) })
                ?? positive(attributes["timeshift"].flatMap { Int($0) })
                ?? positive(recDays),
            catchupSource: nonEmpty(attributes["catchup-source"])
        )
    }

    static func parseHeader(_ line: String) -> M3UHeader {
        let attributes = parseAttributes(line)
        return M3UHeader(epgURL: nonEmpty(attributes["url-tvg"]) ?? nonEmpty(attributes["x-tvg-url"]))
    }

    /// Extracts `key="value"` pairs plus the bare `key=value` form providers
    /// emit for numeric attributes (`catchup-days=1`, `timeshift=2`). A single
    /// manual scan — no regex — because this runs once per line on playlists
    /// with hundreds of thousands of lines.
    ///
    /// Scanning stops at the first comma reached outside a quoted value: on an
    /// `#EXTINF` line that comma starts the display name, and a name like
    /// `Sky F1=HD` must not contribute an attribute. Commas inside a quoted
    /// value are consumed with the value, so this is the same boundary
    /// `parseExtInf` uses to find the name.
    static func parseAttributes(_ text: String) -> [String: String] {
        scanAttributes(text).attributes
    }

    /// `parseAttributes` plus the index the scan stopped on, so `parseExtInf`
    /// does not have to locate the display-name comma a second time.
    private static func scanAttributes(_ text: String) -> (attributes: [String: String], stop: String.Index) {
        var result: [String: String] = [:]
        var index = text.startIndex

        while index < text.endIndex {
            guard let equals = nextEquals(in: text, from: index) else { break }
            let valueStart = text.index(after: equals)
            guard valueStart < text.endIndex else { break }

            // Key: identifier characters immediately before '='.
            var keyStart = equals
            while keyStart > index {
                let previous = text.index(before: keyStart)
                let char = text[previous]
                guard char.isLetter || char.isNumber || char == "-" || char == "_" else { break }
                keyStart = previous
            }
            let key = String(text[keyStart ..< equals])

            if text[valueStart] == "\"" {
                let quoteStart = text.index(after: valueStart)
                guard let quoteEnd = text[quoteStart...].firstIndex(of: "\"") else { break }
                if !key.isEmpty {
                    result[key] = String(text[quoteStart ..< quoteEnd])
                }
                index = text.index(after: quoteEnd)
            } else {
                // An unquoted value ends at the next space or at the comma that
                // starts the display name; a value carrying either must be quoted.
                var valueEnd = valueStart
                while valueEnd < text.endIndex, !text[valueEnd].isWhitespace, text[valueEnd] != "," {
                    valueEnd = text.index(after: valueEnd)
                }
                if !key.isEmpty, valueStart < valueEnd {
                    result[key] = String(text[valueStart ..< valueEnd])
                }
                index = valueEnd
            }
        }
        return (result, index)
    }

    /// Index of the next `=` at or after `start`, or `nil` once the scan hits a
    /// comma — the display-name boundary — or the end of the text.
    private static func nextEquals(in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "," { return nil }
            if char == "=" { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
