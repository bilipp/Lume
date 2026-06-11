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
                return M3UEntry(name: fallbackName, url: line, tvgId: nil, logo: nil, group: pendingGroup)
            }

            let name = info.name.isEmpty ? (info.tvgName ?? line) : info.name
            return M3UEntry(
                name: name,
                url: line,
                tvgId: info.tvgId,
                logo: info.logo,
                group: info.group ?? pendingGroup
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
    }

    /// Parses `#EXTINF:-1 tvg-id="..." tvg-logo="..." group-title="...",Name`.
    ///
    /// Attribute values may contain commas, so the display name is whatever
    /// follows the first comma *after* the last quoted attribute value.
    static func parseExtInf(_ line: String) -> ExtInf {
        let body = String(line.dropFirst("#EXTINF:".count))

        let attributes = parseAttributes(body)

        // Name: after the first comma past the end of the last quoted value.
        var name = ""
        let searchStart: String.Index = if let lastQuote = body.lastIndex(of: "\"") {
            body.index(after: lastQuote)
        } else {
            body.startIndex
        }
        if let comma = body[searchStart...].firstIndex(of: ",") {
            name = String(body[body.index(after: comma)...])
                .trimmingCharacters(in: .whitespaces)
        }

        return ExtInf(
            name: name,
            tvgId: nonEmpty(attributes["tvg-id"]),
            tvgName: nonEmpty(attributes["tvg-name"]),
            logo: nonEmpty(attributes["tvg-logo"]),
            group: nonEmpty(attributes["group-title"])
        )
    }

    static func parseHeader(_ line: String) -> M3UHeader {
        let attributes = parseAttributes(line)
        return M3UHeader(epgURL: nonEmpty(attributes["url-tvg"]) ?? nonEmpty(attributes["x-tvg-url"]))
    }

    /// Extracts `key="value"` pairs (the only attribute form the IPTV dialect
    /// uses in practice). A single manual scan — no regex — because this runs
    /// once per line on playlists with hundreds of thousands of lines.
    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex

        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let valueStart = text.index(after: equals)
            guard valueStart < text.endIndex, text[valueStart] == "\"" else {
                index = valueStart
                continue
            }
            // Key: identifier characters immediately before '='.
            var keyStart = equals
            while keyStart > index {
                let previous = text.index(before: keyStart)
                let char = text[previous]
                guard char.isLetter || char.isNumber || char == "-" || char == "_" else { break }
                keyStart = previous
            }
            let key = String(text[keyStart ..< equals])

            let quoteStart = text.index(after: valueStart)
            guard let quoteEnd = text[quoteStart...].firstIndex(of: "\"") else { break }
            if !key.isEmpty {
                result[key] = String(text[quoteStart ..< quoteEnd])
            }
            index = text.index(after: quoteEnd)
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
