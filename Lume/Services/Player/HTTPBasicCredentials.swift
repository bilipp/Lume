//
//  HTTPBasicCredentials.swift
//  Lume
//
//  Turns the `Authorization: Basic` header a WebDAV `PlayableMedia` carries
//  back into a userinfo URL, for the one engine that cannot send headers.
//

import Foundation

nonisolated enum HTTPBasicCredentials {
    /// The user/password pair inside an `Authorization: Basic <base64>` header
    /// value. Splits on the FIRST colon — a password may contain colons, a
    /// username may not (RFC 7617).
    static func decode(_ headers: [String: String]?) -> (user: String, password: String)? {
        guard let value = headers?["Authorization"] else { return nil }
        let token = value.hasPrefix("Basic ") ? String(value.dropFirst("Basic ".count)) : value
        guard let data = Data(base64Encoded: token),
              let pair = String(data: data, encoding: .utf8),
              let separator = pair.firstIndex(of: ":")
        else { return nil }
        return (String(pair[pair.startIndex ..< separator]), String(pair[pair.index(after: separator)...]))
    }

    /// `scheme://user:pass@host/…` for `url`, or `nil` when there is nothing to
    /// add. VLCKit exposes no arbitrary-header API, so this is the only way to
    /// authenticate it — and the result is transient by contract: it must never
    /// be persisted onto a catalog row, never reach an `ExternalPlayer` deep
    /// link, a Cast payload, `DownloadTaskInfo.taskDescription`, or macOS
    /// window-restoration state. Build it at the point of handoff and let it die
    /// with the call.
    ///
    /// Parsing with `resolvingAgainstBaseURL: false` keeps the path's existing
    /// percent-encoding: WebDAV hrefs arrive encoded (`%5B`), and re-encoding
    /// would turn that into `%255B` and 404.
    static func authenticatedURL(_ url: URL, headers: [String: String]?) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let credentials = decode(headers) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil
        else { return nil }
        components.user = credentials.user
        components.password = credentials.password
        return components.url
    }
}
