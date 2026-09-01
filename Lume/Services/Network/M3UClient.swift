//
//  M3UClient.swift
//  Lume
//
//  Fetches m3u playlists and their XMLTV guides. Everything lands in a temp
//  file and is stream-parsed from disk — playlists and EPGs can be hundreds of
//  megabytes, so nothing is ever held in memory as one blob.
//

import CryptoKit
import Foundation
import OSLog

/// The Xtream account behind an m3u `get.php` URL, when one can be read out of
/// it. Purely a hint: it is offered to the user as "this provider can also be
/// added as an Xtream login", never acted on automatically.
///
/// Nothing here may grow into a conversion. The two pipelines disagree on
/// content identity — m3u derives a stream's id by hashing its URL
/// (`M3UIdentity.hash64`), Xtream uses the provider's own stream ids — so
/// rewriting a playlist's source type in place would give every row a new id.
/// Favourites, watch positions, the CloudKit `UserContentState` records keyed by
/// those ids, and all TMDB enrichment would be orphaned, and the next sweep
/// would delete the rows they pointed at. A user who wants Xtream adds a second
/// playlist and removes the m3u one.
nonisolated struct XtreamCredentialsHint {
    /// Scheme, host and (when non-default) port only — the form an Xtream login
    /// expects. No path, no query: the query is what carries the credentials.
    let baseURL: String
    let username: String
    let password: String
}

/// A playlist file ready to parse, plus a content fingerprint the sync uses to
/// recognise a byte-identical re-download and skip the import entirely.
nonisolated struct M3UPlaylistFile {
    let url: URL
    /// Lowercase hex SHA-256 over the file's bytes, or `nil` when the file could
    /// not be read. `nil` never matches, so an unreadable file always imports.
    let digest: String?
}

nonisolated enum M3UError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case serverError(Int)
    case invalidResponse
    case notAPlaylist
    case enigma2Bouquet
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The playlist URL is invalid."
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .serverError(code):
            "Server error (HTTP \(code))."
        case .invalidResponse:
            "Received an invalid response from the server."
        case .notAPlaylist:
            "The URL does not point to an m3u playlist."
        case .enigma2Bouquet:
            """
            This link returns an Enigma2/Gigablue set-top-box bouquet, not an m3u playlist. \
            Change "type=gigablue" (or "dreambox") to "type=m3u_plus" in the URL, or add the \
            provider as an Xtream login instead.
            """
        case .fileNotFound:
            "The playlist file could not be found."
        }
    }

    /// Credential-free summary for diagnostic logs. Interpolated with
    /// `privacy: .public`, so it must never contain a URL — playlist and EPG
    /// URLs can carry account credentials as query items, and underlying
    /// `NSError` descriptions can embed the failing URL.
    var logDescription: String {
        switch self {
        case .invalidURL:
            return "invalid URL"
        case let .networkError(error):
            let nsError = error as NSError
            return "network error (\(nsError.domain) \(nsError.code))"
        case let .serverError(code):
            return "HTTP \(code)"
        case .invalidResponse:
            return "non-HTTP response"
        case .notAPlaylist:
            return "not an m3u playlist"
        case .enigma2Bouquet:
            return "Enigma2 bouquet URL"
        case .fileNotFound:
            return "file not found"
        }
    }
}

nonisolated class M3UClient {
    let session: URLSession

    init(urlSession: URLSession? = nil) {
        session = urlSession ?? Self.makeSession()
    }

    /// Generous resource timeout: provider playlist exports can be very large
    /// and some servers stream them slowly.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        // Match the Xtream client: some providers serve a block page to an
        // unrecognized UA, breaking the playlist download/parse.
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }

    // MARK: - Download

    /// Fetches the playlist behind `urlString` and returns a local file to parse
    /// from, fingerprinted. Remote playlists download to a temp file; `file://`
    /// URLs (imported local files) are returned as-is.
    ///
    /// Only playlists are hashed, not EPG guides: the fingerprint exists to skip
    /// the m3u import, and hashing every guide download would buy nothing.
    func downloadPlaylist(from urlString: String) async throws -> M3UPlaylistFile {
        guard let url = URL(string: Self.normalizedPlaylistURL(urlString)) else {
            throw M3UError.invalidURL
        }

        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw M3UError.fileNotFound
            }
            return M3UPlaylistFile(url: url, digest: Self.sha256Hex(ofFileAt: url))
        }

        let downloaded = try await download(url, suffix: ".m3u")
        return M3UPlaylistFile(url: downloaded, digest: Self.sha256Hex(ofFileAt: downloaded))
    }

    /// Streams a file through SHA-256 a megabyte at a time. Never loads the
    /// whole file: a provider playlist is half a gigabyte, and the download
    /// already landed it on disk. Reading it back costs ~0.28 s at that size,
    /// against the minutes an import of the same bytes would take.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var reachedEnd = false
        // Each chunk is released inside the pool: this runs inside the sync
        // actor's uninterrupted synchronous stretch, where the enclosing pool
        // never drains, and 520 undrained megabyte buffers is the whole file
        // back in memory.
        while !reachedEnd {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: hashChunkSize), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let hashChunkSize = 1 << 20

    /// Downloads an XMLTV guide to a temp file for streaming parse. Gzipped
    /// guides (`guide.xml.gz` — the common way public EPGs are hosted) are
    /// decompressed to a fresh temp file first.
    func downloadEPG(from urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else { throw M3UError.invalidURL }

        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw M3UError.fileNotFound
            }
            return try gunzipIfNeeded(url, deleteOriginal: false)
        }

        let downloaded = try await download(url, suffix: ".xmltv")
        return try gunzipIfNeeded(downloaded, deleteOriginal: true)
    }

    private func gunzipIfNeeded(_ fileURL: URL, deleteOriginal: Bool) throws -> URL {
        guard GzipFile.isGzip(fileURL) else { return fileURL }
        Logger.network.info("EPG file is gzipped, decompressing")
        let decompressed = try GzipFile.decompress(fileURL)
        if deleteOriginal {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return decompressed
    }

    private func download(_ url: URL, suffix: String) async throws -> URL {
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(from: url)
        } catch {
            throw M3UError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw M3UError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw M3UError.serverError(httpResponse.statusCode)
        }

        // Move to a stable location before the system cleans it up.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + suffix)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    // MARK: - Validation

    /// Cheaply verifies that `urlString` points at an m3u playlist by streaming
    /// only the first few kilobytes and looking for `#EXTM3U` / `#EXTINF`
    /// markers — no full download, so adding a 100 MB playlist stays instant.
    func validatePlaylist(at urlString: String) async throws {
        guard let url = URL(string: Self.normalizedPlaylistURL(urlString)) else {
            throw M3UError.invalidURL
        }

        let head = url.isFileURL
            ? try localFileHead(url)
            : try await remoteHead(url)
        guard Self.looksLikePlaylist(head) else {
            // A rewritten `type` didn't take (server ignored it) or the user
            // pasted a raw bouquet URL we can't fix — give a specific hint
            // instead of the generic "not a playlist" error.
            throw Self.looksLikeEnigma2Bouquet(head) ? M3UError.enigma2Bouquet : M3UError.notAPlaylist
        }
    }

    private func localFileHead(_ url: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw M3UError.fileNotFound
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 64 * 1024)) ?? Data()
    }

    private func remoteHead(_ url: URL) async throws -> Data {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(from: url)
        } catch {
            throw M3UError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode)
        {
            throw M3UError.serverError(httpResponse.statusCode)
        }

        var head = Data()
        head.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 64 * 1024 { break }
            }
        } catch {
            // A truncated read is fine as long as we already saw enough bytes
            // to recognize the format.
            if head.isEmpty { throw M3UError.networkError(error) }
        }
        return head
    }

    /// True when the first chunk of a file contains m3u markers. Checks
    /// `#EXTINF` as well as `#EXTM3U` because some provider exports omit the
    /// header line.
    static func looksLikePlaylist(_ head: Data) -> Bool {
        guard let text = String(bytes: head, encoding: .utf8)
            ?? String(bytes: head, encoding: .isoLatin1)
        else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#EXTM3U") || trimmed.hasPrefix("#EXTINF") { return true }
            // First meaningful line is something else — not an extended m3u,
            // unless the whole thing is a plain list of URLs.
            return trimmed.contains("://")
        }
        return false
    }

    /// True when a response is an Enigma2 / Gigablue / Dreambox `userbouquet`
    /// export rather than an m3u — these use `#NAME` / `#SERVICE` /
    /// `#DESCRIPTION` markers and never parse as a playlist. Providers hand one
    /// out when a `get.php` URL carries `type=gigablue` (or `dreambox`).
    static func looksLikeEnigma2Bouquet(_ head: Data) -> Bool {
        guard let text = String(bytes: head, encoding: .utf8)
            ?? String(bytes: head, encoding: .isoLatin1)
        else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#EXTM3U") || trimmed.hasPrefix("#EXTINF") { return false }
            if trimmed.hasPrefix("#SERVICE") || trimmed.hasPrefix("#NAME") { return true }
        }
        return false
    }

    /// Xtream `get.php` links yield a parseable playlist for `type=m3u` and
    /// `type=m3u_plus`; any other value (`gigablue`, `dreambox`, `enigma2`, …)
    /// returns a set-top-box bouquet that can't be parsed. We always rewrite to
    /// `m3u_plus` — including plain `m3u`, which is the canonical `get.php`
    /// default users paste — because `m3u_plus` is a strict superset: plain
    /// `m3u` omits the `tvg-logo` / `tvg-id` / `group-title` attributes, so
    /// posters, channel logos and categories all go missing, while `m3u_plus`
    /// carries them. Only already-`m3u_plus` URLs and non-`get.php` URLs pass
    /// through untouched. Keeping this in the client means both freshly-added
    /// and already-stored playlists self-heal on their next fetch.
    static func normalizedPlaylistURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              components.path.hasSuffix("get.php"),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "type" }),
              let type = items[index].value?.lowercased(),
              type != "m3u_plus"
        else { return urlString }

        items[index].value = "m3u_plus"
        components.queryItems = items
        return components.string ?? urlString
    }

    /// Reads the Xtream account out of an m3u URL that is really an Xtream
    /// `get.php` endpoint, or returns `nil` when it is an ordinary playlist URL.
    ///
    /// Same URL shape `normalizedPlaylistURL(_:)` already handles: a `get.php`
    /// path carrying `username` and `password` query items. Both must be present
    /// and non-empty — a `get.php` link without them is not an account we could
    /// offer to add.
    ///
    /// Advisory only; see `XtreamCredentialsHint` for why this must never drive
    /// an automatic conversion. Callers that log around this must pass the URL
    /// through `LogRedaction.scrubURLs` — these URLs carry the credentials as
    /// query items.
    static func xtreamCredentials(in urlString: String) -> XtreamCredentialsHint? {
        guard let components = URLComponents(string: urlString),
              components.path.hasSuffix("get.php"),
              let scheme = components.scheme,
              let host = components.host, !host.isEmpty,
              let items = components.queryItems,
              let username = items.first(where: { $0.name == "username" })?.value, !username.isEmpty,
              let password = items.first(where: { $0.name == "password" })?.value, !password.isEmpty
        else { return nil }

        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = components.port
        guard let baseURL = base.string else { return nil }
        return XtreamCredentialsHint(baseURL: baseURL, username: username, password: password)
    }
}
