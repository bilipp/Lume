//
//  DownloadValidation.swift
//  Lume
//
//  Cheap completion checks for offline media downloads. This deliberately
//  rejects only responses that cannot be playable media; codec/container
//  probing belongs to playback and would make the background-session delegate
//  both expensive and hostile to provider-specific formats.
//

import Foundation

nonisolated enum DownloadValidationError: Error, Equatable {
    case httpStatus(Int)
    case emptyFile
    case unsupportedContentType(String)
    case unsupportedPayload
}

nonisolated enum DownloadValidator {
    private static let prefixByteCount = 512
    private static let manifestContentTypes: Set<String> = [
        "application/mpegurl",
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl"
    ]

    /// Ensures a transfer produced a real, non-empty file and not an HTTP or
    /// provider error document. Opaque and mislabelled binary media is accepted.
    static func validate(fileAt url: URL, response: URLResponse?) throws {
        if let http = response as? HTTPURLResponse,
           !(200 ... 299).contains(http.statusCode)
        {
            throw DownloadValidationError.httpStatus(http.statusCode)
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
            throw DownloadValidationError.emptyFile
        }

        let prefix = try prefix(of: url)
        if looksLikeUnsupportedPayload(prefix) {
            throw DownloadValidationError.unsupportedPayload
        }

        guard let contentType = response?.mimeType?.lowercased() else { return }
        if isStructuredErrorType(contentType)
            || manifestContentTypes.contains(contentType)
            || contentType.hasPrefix("text/") && looksLikeText(prefix)
        {
            throw DownloadValidationError.unsupportedContentType(contentType)
        }
    }

    /// Recovery has no response metadata, but should still require the same
    /// usable on-disk artifact rather than treating path existence as success.
    static func isUsableFile(at url: URL) -> Bool {
        do {
            try validate(fileAt: url, response: nil)
            return true
        } catch {
            return false
        }
    }

    private static func prefix(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: prefixByteCount) ?? Data()
    }

    private static func isStructuredErrorType(_ contentType: String) -> Bool {
        contentType == "application/json"
            || contentType.hasSuffix("+json")
            || contentType == "application/xml"
            || contentType.hasSuffix("+xml")
    }

    private static func looksLikeUnsupportedPayload(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.hasPrefix("<!doctype html")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<?xml")
            || prefix.hasPrefix("#extm3u")
            || prefix.hasPrefix("{")
            || prefix.hasPrefix("[")
    }

    private static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { return false }
        return !data.contains(0)
    }
}
