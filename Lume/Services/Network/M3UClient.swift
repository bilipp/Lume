//
//  M3UClient.swift
//  Lume
//
//  Fetches m3u playlists and their XMLTV guides. Everything lands in a temp
//  file and is stream-parsed from disk — playlists and EPGs can be hundreds of
//  megabytes, so nothing is ever held in memory as one blob.
//

import Foundation
import OSLog

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

    /// Fetches the playlist behind `urlString` and returns a local file URL to
    /// parse from. Remote playlists download to a temp file; `file://` URLs
    /// (imported local files) are returned as-is.
    func downloadPlaylist(from urlString: String) async throws -> URL {
        guard let url = URL(string: Self.normalizedPlaylistURL(urlString)) else {
            throw M3UError.invalidURL
        }

        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw M3UError.fileNotFound
            }
            return url
        }

        return try await download(url, suffix: ".m3u")
    }

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

    /// Xtream `get.php` links only yield an m3u when `type` is `m3u` or
    /// `m3u_plus`. Any other value (`gigablue`, `dreambox`, `enigma2`, …)
    /// returns a set-top-box bouquet that can't be parsed, so rewrite it to
    /// `m3u_plus`. Non-`get.php` URLs and already-valid types pass through
    /// untouched. Keeping this in the client means both freshly-added and
    /// already-stored playlists self-heal on their next fetch.
    static func normalizedPlaylistURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              components.path.hasSuffix("get.php"),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "type" }),
              let type = items[index].value?.lowercased(),
              type != "m3u", type != "m3u_plus"
        else { return urlString }

        items[index].value = "m3u_plus"
        components.queryItems = items
        return components.string ?? urlString
    }
}
