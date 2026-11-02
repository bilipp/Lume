import Foundation

/// What a download fetches for a catalog row, kept free of models and the
/// session so the per-source rules can be tested on their own.
nonisolated enum DownloadSource {
    /// The URL to download for a row whose stored playback URL is `stored`.
    /// `xtream` builds the URL for an Xtream row, which may store none.
    ///
    /// Jellyfin and Emby go through the server's download route rather than
    /// the stream route, so an account the admin barred from downloading is
    /// refused there. Silo's compatibility service is only known to serve the
    /// stream route, so it downloads what it plays.
    static func url(stored: URL?, sourceType: PlaylistSourceType, xtream: () -> URL?) -> URL? {
        switch sourceType {
        case .xtream: stored ?? xtream()
        case .m3u, .webdav, .plex, .silo: stored
        case .jellyfin, .emby: stored.flatMap(JellyfinClient.downloadURL(forStreamURL:))
        case .stalker: nil
        }
    }

    /// The request for `url`, carrying the credential the source needs as
    /// headers. A background session persists the request with the task, so
    /// the headers survive the app being relaunched mid-transfer.
    static func request(url: URL, headers: [String: String]?) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// A file extension for a stored container name. Media servers report a
    /// format family rather than an extension (Jellyfin's MP4 is
    /// `mov,mp4,m4a,3gp,3g2,mj2`); AVPlayer picks its parser by extension, so
    /// `mp4` wins when listed, otherwise the first entry.
    static func fileExtension(container: String?, fallback: String = "mp4") -> String {
        let candidates = (container ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
            .filter { !$0.isEmpty }
        if candidates.contains("mp4") { return "mp4" }
        return candidates.first ?? fallback
    }

    /// Whether a finished transfer is the file rather than an error page. A
    /// download task completes without error on any HTTP status, so a 401,
    /// 403 or 404 body would otherwise be saved as the movie.
    static func isAcceptable(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200 ..< 300).contains(http.statusCode)
    }
}
