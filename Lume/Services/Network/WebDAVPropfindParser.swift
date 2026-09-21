//
//  WebDAVPropfindParser.swift
//  Lume
//
//  SAX parser for a WebDAV `PROPFIND` multistatus body.
//

import Foundation

/// One entry of a WebDAV collection listing.
nonisolated struct WebDAVResource: Hashable {
    /// Absolute URL with the server's own percent-encoding preserved byte for
    /// byte. Re-encoding turns `%5b` into `%255b` (404) and decoding produces a
    /// literal `[`, which `URL(string:)` rejects outright.
    let url: URL
    /// Percent-decoded last path segment, for display and filename parsing.
    let name: String
    let isCollection: Bool
    let contentLength: Int64?
    let contentType: String?
    let etag: String?
    let lastModified: Date?
}

/// Parses a `207 Multi-Status` body into the children of the collection that
/// was asked about.
///
/// Namespace-aware by necessity: Apache mod_dav returns properties under a
/// second prefix (`lp1:`) that is also bound to `DAV:`, mixed with `D:` ones,
/// while Nextcloud uses `d:`. Matching qualified names silently yields zero
/// entries against one server or the other.
final nonisolated class WebDAVPropfindParser: NSObject, XMLParserDelegate {
    /// Returns the collection's children, or `nil` when the payload is not a
    /// parseable `DAV:multistatus` — which is how a 200-with-HTML from a plain
    /// web server is told apart from an empty collection.
    static func parse(_ data: Data, collection: URL) -> [WebDAVResource]? {
        let parser = WebDAVPropfindParser(collection: collection)
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldProcessNamespaces = true
        xmlParser.delegate = parser
        guard xmlParser.parse(), parser.sawMultistatus else { return nil }
        return parser.resources
    }

    private let collection: URL
    private let collectionKey: String
    private var resources: [WebDAVResource] = []
    private var sawMultistatus = false
    private var isFirstResponse = true

    private var inResponse = false
    private var inResourceType = false
    private var href: String?
    private var isCollectionResource = false
    private var contentLength: Int64?
    private var contentType: String?
    private var etag: String?
    private var lastModified: Date?
    private var text = ""

    private let httpDateFormatter: DateFormatter

    private init(collection: URL) {
        collectionKey = Self.pathKey(collection.absoluteString)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        httpDateFormatter = formatter
        self.collection = collection
    }

    // MARK: - XMLParserDelegate

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes _: [String: String] = [:]
    ) {
        text = ""
        guard Self.isDAV(namespaceURI) else { return }

        switch elementName {
        case "multistatus":
            sawMultistatus = true
        case "response":
            beginResponse()
        case "resourcetype":
            inResourceType = true
        case "collection":
            if inResourceType { isCollectionResource = true }
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard inResponse else { return }
        text += string
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName _: String?
    ) {
        guard inResponse, Self.isDAV(namespaceURI) else { return }

        switch elementName {
        case "response":
            endResponse()
        case "resourcetype":
            inResourceType = false
        default:
            apply(elementName, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func apply(_ elementName: String, _ value: String) {
        guard !value.isEmpty else { return }
        switch elementName {
        case "href":
            // Only the response's own href; a nested `<D:location>` href must
            // not overwrite it.
            if href == nil { href = value }
        case "getcontentlength":
            if let length = Int64(value) { contentLength = length }
        case "getcontenttype":
            contentType = value
        case "getetag":
            etag = value
        case "getlastmodified":
            lastModified = httpDateFormatter.date(from: value)
        default:
            break
        }
    }

    // MARK: - Response assembly

    private func beginResponse() {
        inResponse = true
        inResourceType = false
        href = nil
        isCollectionResource = false
        contentLength = nil
        contentType = nil
        etag = nil
        lastModified = nil
    }

    private func endResponse() {
        defer {
            inResponse = false
            isFirstResponse = false
        }
        guard let href, let url = URL(string: href, relativeTo: collection)?.absoluteURL else { return }

        // The collection asked about is returned as the first response. Emitting
        // it would give every directory a phantom row and leave the recursive
        // walk descending into itself forever.
        guard !isFirstResponse, Self.pathKey(url.absoluteString) != collectionKey else { return }
        guard let name = Self.lastSegment(of: href) else { return }

        resources.append(WebDAVResource(
            url: url,
            name: name,
            isCollection: isCollectionResource,
            contentLength: contentLength,
            contentType: contentType,
            etag: etag,
            lastModified: lastModified
        ))
    }

    // MARK: - Helpers

    private static func isDAV(_ namespaceURI: String?) -> Bool {
        // A non-conformant server that emits no namespaces at all still parses.
        namespaceURI == nil || namespaceURI == "DAV:"
    }

    /// Percent-decoded last non-empty path segment of an href, so a directory
    /// (`/Movies/Action/`) yields its own name rather than an empty string.
    private static func lastSegment(of href: String) -> String? {
        let path = href.split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
        guard let segment = path.split(separator: "/").last else { return nil }
        let decoded = segment.removingPercentEncoding ?? String(segment)
        return decoded.isEmpty ? nil : decoded
    }

    /// Identity used to recognise a response that describes the collection
    /// itself. Percent-decoded and trailing-slash-insensitive: a server may
    /// spell its own href differently from the URL we requested.
    private static func pathKey(_ absoluteString: String) -> String {
        let withoutQuery = absoluteString.split(separator: "?", maxSplits: 1).first.map(String.init)
            ?? absoluteString
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }
}
