//
//  M3UParser.swift
//  Lume
//
//  Streaming parser for m3u / m3u8 playlists (the "extended m3u" IPTV dialect:
//  #EXTINF lines with tvg-* attributes followed by a stream URL).
//
//  Like XMLTVParser, it never holds the whole file in memory: the file is read
//  in fixed-size chunks, split into lines, and parsed entries are handed to the
//  caller in batches. Chunking alone is not enough — the per-line temporaries
//  are autoreleased, and the sync actor's import job offers no suspension point
//  for the enclosing pool to drain at, so the chunk loop drains its own pool per
//  iteration. That is what makes a multi-hundred-megabyte provider export parse
//  with flat memory.
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
}

// MARK: - Parser

nonisolated enum M3UParser {
    /// Bytes read from disk per chunk. Large enough to amortize I/O, small
    /// enough to keep memory flat.
    private static let chunkSize = 512 * 1024

    /// Reads just the `#EXTM3U` header, without parsing the entries behind it.
    ///
    /// The header is the file's first non-empty line, so one chunk always
    /// carries it. This exists for the skip-if-unchanged path: a playlist whose
    /// bytes are unchanged still has to surrender its `url-tvg` to a user who
    /// has since cleared their guide URL, and re-parsing half a gigabyte of
    /// entries to reach line one would give the whole skip back.
    ///
    /// Returns `nil` for a file that is unreadable or carries no header line.
    static func readHeader(fileURL: URL) -> M3UHeader? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil else { return nil }

        for lineData in chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let raw = String(bytes: lineData, encoding: .utf8)
                ?? String(bytes: lineData, encoding: .isoLatin1)
            guard let line = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }
            guard line.hasPrefix("#EXTM3U") else { return nil }
            return parseHeader(line)
        }
        return nil
    }

    /// Parses an m3u file from disk, calling `onBatch` for every `batchSize`
    /// entries (and once more with the remainder). Returns the total entry count.
    ///
    /// `onHeader` fires at most once, as soon as the `#EXTM3U` line is seen —
    /// before any batch — so callers can pick up the embedded EPG URL.
    ///
    /// `onBatch`'s second argument is how many bytes of the file have been
    /// consumed at that point. A streaming parse doesn't know the entry count
    /// until it ends, so bytes-over-file-size is the only progress fraction a
    /// caller can report honestly while the import is running. It may suspend:
    /// the m3u import's producer hands each batch to a bounded channel and parks
    /// there whenever the writer falls behind.
    ///
    /// The hand-off happens *outside* the per-chunk `autoreleasepool` — an
    /// `await` may not cross one — so a chunk's completed batches are collected
    /// first and delivered after the pool drains. A 512 KB chunk holds well
    /// under two provider-shaped batches, so that collection is bounded. The
    /// pool itself is per chunk, not per file: `subdata`, `String(bytes:)` and
    /// `trimmingCharacters` autorelease once per line, and without it a 520 MB
    /// playlist peaks at ~502 MB resident.
    @discardableResult
    static func parseStreaming(
        fileURL: URL,
        batchSize: Int = 2000,
        onHeader: ((M3UHeader) -> Void)? = nil,
        onBatch: ([M3UEntry], _ bytesConsumed: Int) async throws -> Void
    ) async throws -> Int {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var reader = ChunkedEntryReader(handle: handle, batchSize: batchSize)
        while !reader.isFinished {
            let ready = autoreleasepool { reader.readChunk(onHeader: onHeader) }
            for batch in ready {
                try await onBatch(batch.entries, batch.bytesConsumed)
            }
        }
        if let final = reader.finalBatch() {
            try await onBatch(final.entries, final.bytesConsumed)
        }
        return reader.totalCount
    }

    // MARK: - Chunk loop

    /// One completed batch on its way out of `ChunkedEntryReader`.
    private typealias ReadyBatch = (entries: [M3UEntry], bytesConsumed: Int)

    /// The chunk loop behind `parseStreaming`: reads the file in fixed-size
    /// blocks, splits complete lines out of the carry buffer and accumulates
    /// entries until a batch fills.
    private nonisolated struct ChunkedEntryReader {
        private let handle: FileHandle
        private let batchSize: Int
        private var state = ParseState()
        private var batch: [M3UEntry] = []
        private var carry = Data()
        /// Bytes of the file already handed to the line loop, excluding the
        /// block currently being walked.
        private var consumedBase = 0
        private(set) var isFinished = false
        private(set) var totalCount = 0

        init(handle: FileHandle, batchSize: Int) {
            self.handle = handle
            self.batchSize = batchSize
            batch.reserveCapacity(batchSize)
        }

        /// Reads the next chunk and returns whatever batches it completed —
        /// usually none or one.
        mutating func readChunk(onHeader: ((M3UHeader) -> Void)?) -> [ReadyBatch] {
            let chunk = (try? handle.read(upToCount: M3UParser.chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty {
                carry.append(chunk)
            } else {
                isFinished = true
            }

            // Split everything up to the last newline into lines; the tail
            // (a partial line) stays in `carry` for the next chunk. At EOF the
            // whole remainder is one final line.
            let processable: Data
            if isFinished {
                processable = carry
                carry = Data()
            } else if let lastNewline = carry.lastIndex(of: UInt8(ascii: "\n")) {
                processable = carry.subdata(in: carry.startIndex ..< lastNewline)
                carry = carry.subdata(in: carry.index(after: lastNewline) ..< carry.endIndex)
            } else {
                // No complete line buffered yet.
                return []
            }

            let blockStart = processable.startIndex
            defer { consumedBase += processable.count + 1 }

            var ready: [ReadyBatch] = []
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
                        ready.append((batch, consumedBase + (lineData.endIndex - blockStart)))
                        // Handing the array out shares its buffer, so
                        // `removeAll(keepingCapacity:)` would have to copy;
                        // a fresh right-sized one instead of re-growing 0→2,000.
                        batch = []
                        batch.reserveCapacity(batchSize)
                    }
                }
            }
            return ready
        }

        /// The trailing partial batch, once the file is exhausted.
        mutating func finalBatch() -> ReadyBatch? {
            guard !batch.isEmpty else { return nil }
            defer { batch = [] }
            return (batch, consumedBase)
        }
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
                return M3UEntry(name: fallbackName, url: line, tvgId: nil, logo: nil, group: pendingGroup, type: nil)
            }

            let name = info.name.isEmpty ? (info.tvgName ?? line) : info.name
            return M3UEntry(
                name: name,
                url: line,
                tvgId: info.tvgId,
                logo: info.logo,
                group: info.group ?? pendingGroup,
                type: info.type
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
            group: nonEmpty(attributes["group-title"]),
            type: nonEmpty(attributes["type"])
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
