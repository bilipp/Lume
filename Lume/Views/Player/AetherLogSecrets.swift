//
//  AetherLogSecrets.swift
//  Lume
//
//  The credentials in a stream request that only Lume can name. AetherEngine
//  scrubs the shapes it recognises from every log line (named parameters,
//  userinfo passwords, the password of the long Xtream Codes layout
//  `/live/{user}/{password}/{id}`), but it leaves that layout's user name in
//  its `load url=` line; the short layout `/{user}/{password}/{id}` many m3u
//  providers use has no marker to go by; and a header value is only a
//  credential because Lume put it there. Those are registered with the engine
//  for the length of a load.
//

#if !os(visionOS)

    import Foundation

    nonisolated enum AetherLogSecrets {
        /// The engine refuses shorter values, which would black out ordinary text.
        static let minimumLength = 4

        /// Path words a short-layout URL can carry where the account would
        /// sit; registering one would redact it from every engine line.
        private static let routeWords: Set<String> = [
            "auth", "channel", "channels", "dash", "get", "hls", "iptv", "live",
            "media", "movie", "movies", "play", "playlist", "proxy", "series",
            "stream", "streams", "timeshift", "video", "videos", "vod"
        ]

        /// The first path word of the long Xtream Codes layout.
        private static let longLayoutRoutes: Set<String> = ["live", "movie", "series", "timeshift"]

        private static let quotedTokenPattern = /(?i)token="([^"]+)"/

        static func values(url: URL, httpHeaders: [String: String]?) -> Set<String> {
            var values: Set<String> = []
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                values.formUnion([components.user, components.password].compactMap(\.self))
            }
            values.formUnion(shortXtreamCredentials(in: url))
            values.formUnion(longXtreamCredentials(in: url))
            for value in (httpHeaders ?? [:]).values {
                values.insert(value)
                // `Bearer <token>`, `Basic <base64>`: the token also travels alone.
                if let space = value.firstIndex(of: " ") {
                    values.insert(String(value[value.index(after: space)...]))
                }
                // Jellyfin's `MediaBrowser …, Token="<token>"`.
                for match in value.matches(of: quotedTokenPattern) {
                    values.insert(String(match.output.1))
                }
            }
            return values.filter { $0.utf8.count >= minimumLength }
        }

        /// `/{user}/{password}/{id}` with a numeric id (and an optional
        /// extension): the account is the two segments before it.
        static func shortXtreamCredentials(in url: URL) -> [String] {
            let segments = pathSegments(of: url)
            guard segments.count == 3 else { return [] }
            let id = segments[2].split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            guard !id.isEmpty, id.allSatisfy(\.isASCIIDigit) else { return [] }
            return segments[0 ... 1].filter { !routeWords.contains($0.lowercased()) }
        }

        /// `/live|movie|series|timeshift/{user}/{password}/…`: the account is
        /// the two segments after the route.
        static func longXtreamCredentials(in url: URL) -> [String] {
            let segments = pathSegments(of: url)
            guard segments.count >= 4, longLayoutRoutes.contains(segments[0].lowercased()) else { return [] }
            return segments[1 ... 2].filter { !routeWords.contains($0.lowercased()) }
        }

        private static func pathSegments(of url: URL) -> [String] {
            url.path(percentEncoded: false)
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
        }
    }

    private nonisolated extension Character {
        var isASCIIDigit: Bool {
            isASCII && isNumber
        }
    }

#endif
