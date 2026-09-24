//
//  WebDAVClient.swift
//  Lume
//
//  Lists a WebDAV collection over `PROPFIND`. One request per directory: the
//  recursive walk lives in the sync layer, not here.
//

import Foundation

/// Basic-auth credentials for a WebDAV share. `nil` anywhere one of these is
/// expected means an anonymous share.
nonisolated struct WebDAVCredentials: Hashable {
    let username: String
    let password: String

    /// Sent preemptively on every request: a 401 challenge round-trip per
    /// directory doubles the request count of a deep walk.
    var basicAuthorizationHeader: String {
        let pair = Data("\(username):\(password)".utf8)
        return "Basic \(pair.base64EncodedString())"
    }
}

nonisolated enum WebDAVError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case unauthorized
    case notAWebDAVServer
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The share URL is invalid.")
        case let .networkError(error):
            String(localized: "Network error: \(error.localizedDescription)")
        case .unauthorized:
            String(localized: "The server rejected these credentials.")
        case .notAWebDAVServer:
            String(localized: "This URL does not point to a WebDAV share. Enter the full path of the shared folder.")
        case let .serverError(code):
            String(localized: "Server error (HTTP \(code)).")
        case .invalidResponse:
            String(localized: "The server returned a response Lume could not read.")
        }
    }

    /// Credential-free summary for diagnostic logs. Interpolated with
    /// `privacy: .public`, so it must never carry a URL or a password — a
    /// WebDAV URL can be pasted with embedded userinfo, and an underlying
    /// `NSError` description can embed the failing URL.
    var logDescription: String {
        switch self {
        case .invalidURL:
            "invalid URL"
        case let .networkError(error):
            "network error (\((error as NSError).domain) \((error as NSError).code))"
        case .unauthorized:
            "HTTP 401 unauthorized"
        case .notAWebDAVServer:
            "not a WebDAV server"
        case let .serverError(code):
            "HTTP \(code)"
        case .invalidResponse:
            "unreadable multistatus response"
        }
    }
}

/// `Sendable` because the walk hands it to a `@concurrent` producer: the only
/// stored property is an immutable `URLSession`.
final nonisolated class WebDAVClient: Sendable {
    let session: URLSession

    init(urlSession: URLSession? = nil) {
        session = urlSession ?? Self.makeSession()
    }

    /// Matches the m3u client: a generous resource timeout for slow NAS boxes,
    /// and a recognizable User-Agent because some shares sit behind a proxy
    /// that blocks unknown clients.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }

    // MARK: - Listing

    /// Lists the immediate children of `collection`.
    ///
    /// `Depth: 1` rather than `infinity`, which Apache mod_dav refuses with a
    /// 403 — the walk recurses one request per directory instead.
    func list(_ collection: URL, credentials: WebDAVCredentials?) async throws -> [WebDAVResource] {
        let base = Self.normalizedCollectionURL(collection)
        let (data, response) = try await send(propfind: base, depth: "1", credentials: credentials)
        try Self.validate(response)

        guard let resources = WebDAVPropfindParser.parse(data, collection: base) else {
            // A plain web server answers PROPFIND with its index page; the
            // add-playlist screen needs to say that rather than "no files".
            throw response.statusCode == 207 ? WebDAVError.invalidResponse : WebDAVError.notAWebDAVServer
        }
        return resources
    }

    /// Cheap reachability + credential check for the add-playlist connection
    /// test: `Depth: 0` asks only about the collection itself, so a share with
    /// thousands of files answers as fast as an empty one.
    func probe(_ collection: URL, credentials: WebDAVCredentials?) async throws {
        let base = Self.normalizedCollectionURL(collection)
        let (data, response) = try await send(propfind: base, depth: "0", credentials: credentials)
        try Self.validate(response)

        guard WebDAVPropfindParser.parse(data, collection: base) != nil else {
            throw response.statusCode == 207 ? WebDAVError.invalidResponse : WebDAVError.notAWebDAVServer
        }
    }

    // MARK: - Request

    private func send(
        propfind url: URL,
        depth: String,
        credentials: WebDAVCredentials?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let header = credentials?.basicAuthorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data(Self.propfindBody.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebDAVError.networkError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        return (data, httpResponse)
    }

    /// 207 is the success status for `PROPFIND`; an `== 200` check rejects every
    /// valid response.
    private static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 207, 200:
            break
        case 401:
            throw WebDAVError.unauthorized
        case 405, 501:
            // The server does not implement PROPFIND at all.
            throw WebDAVError.notAWebDAVServer
        default:
            throw WebDAVError.serverError(response.statusCode)
        }
    }

    /// Only the properties the catalog build needs. Requesting `allprop` makes
    /// Apache and Nextcloud return dozens of extra elements per entry, which on
    /// a large share is megabytes of XML per directory.
    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:">\
    <D:prop>\
    <D:resourcetype/>\
    <D:getcontentlength/>\
    <D:getlastmodified/>\
    <D:getetag/>\
    <D:getcontenttype/>\
    </D:prop>\
    </D:propfind>
    """

    /// A collection URL must end in a slash: without it the server answers with
    /// a 301 to the slashed form (which drops the PROPFIND body) and relative
    /// href resolution loses the last path segment.
    static func normalizedCollectionURL(_ url: URL) -> URL {
        guard !url.absoluteString.hasSuffix("/") else { return url }
        return URL(string: url.absoluteString + "/") ?? url
    }
}
