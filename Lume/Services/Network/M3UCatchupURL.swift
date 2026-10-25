//
//  M3UCatchupURL.swift
//  Lume
//
//  Catch-up (archive) URL construction for m3u channels
//

import Foundation

/// Builds catch-up (archive) URLs for channels that came from an m3u playlist.
///
/// m3u providers describe their archive with a `catchup` dialect plus an
/// optional `catchup-source` template instead of Xtream credentials, so there is
/// nothing to ask a client for: every dialect is a pure rewrite of the channel's
/// own live URL. Modelled on `XtreamClient.buildCatchupURL`, and on the
/// parse-with-`URLComponents`-or-bail style of `PlaylistStreamFormat.applied(to:)`
/// — anything that does not match a known shape returns `nil` rather than a
/// guess.
///
/// Timestamps are raw UTC unix epochs and `{duration}` is **seconds**. The
/// minutes-and-wall-clock convention of `XtreamClient.timeshiftStartString`
/// exists to keep XC panels from answering 400 and is only reached through the
/// `xc` dialect below.
nonisolated enum M3UCatchupURL {
    /// Catch-up URL for the programme running `start ..< end` on the channel
    /// whose live URL is `liveURL`.
    ///
    /// `liveURL` must be the **raw** `LiveStream.directURL`, never the result of
    /// `PlaylistStreamFormat.applied(to:)`: that rewrite swaps `.m3u8` ⇄ `.ts` on
    /// live URLs and would turn a Flussonic archive URL into a 404 for everyone
    /// who set the playlist to MPEG-TS.
    static func build(
        liveURL: URL,
        type: CatchupType,
        source: String?,
        start: Date,
        end: Date,
        now: Date = Date()
    ) -> URL? {
        let duration = Int(end.timeIntervalSince(start).rounded())
        guard duration > 0 else { return nil }
        let template = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = { template.flatMap { $0.isEmpty ? nil : expand($0, start: start, end: end, now: now, duration: duration) } }

        let built: URL? = switch type {
        case .flussonic:
            // `catchup="flussonic"` paired with an explicit `catchup-source` is a
            // common shipping combination, and an explicit template is the
            // provider telling us where its archive actually lives — it wins over
            // the filename convention. The convention is the fallback, for the
            // (equally common) channels that ship the dialect on its own or ship
            // a template we cannot turn into a playable URL.
            expanded().flatMap { playable(resolve($0, against: liveURL, bareToken: .reject)) }
                ?? flussonicURL(liveURL: liveURL, start: start, duration: duration)
        case .append:
            expanded().flatMap { resolve($0, against: liveURL, bareToken: .append) }
        case .default, .shift:
            expanded().flatMap { resolve($0, against: liveURL, bareToken: .reject) }
        case .xc:
            xcURL(liveURL: liveURL, start: start, end: end)
        }
        return playable(built)
    }

    /// The player can only open an absolute http(s) URL, and `canBuild` is what
    /// the importer persists as `tvArchive` — so a dialect that produced
    /// something else (`plugin://…`, a bare query, a path with no host) has to
    /// read as *not buildable* here rather than badge a channel whose catch-up
    /// tap is dead.
    private static func playable(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false
        else { return nil }
        return url
    }

    /// What a `catchup-source` that is neither a whole URL nor a query fragment
    /// means: for `append` the provider wrote a suffix to glue on, everywhere
    /// else only an explicitly relative path counts.
    private enum BareTokenPolicy {
        case append
        case reject
    }

    /// `catchup-source` is often written relative to the channel's own live URL
    /// rather than as a whole URL: a bare query fragment merges onto the live
    /// URL the way `append` does, and a path resolves against it. Anything
    /// already carrying a scheme — or a network-path reference (`//host/path`)
    /// that borrows the live URL's scheme — is taken as written, including under
    /// `.append`, where concatenating it would produce
    /// `http://live/ch.tshttp://archive/x.m3u8`: still http, still with a host,
    /// and so a dead tap that `playable` cannot catch.
    ///
    /// Under `.reject` the shape test is deliberately a positive one.
    /// `URL(string:relativeTo:)` resolves *any* scheme-less string against the
    /// live URL, so a bare token (`garbage`, a stray provider comment) would come
    /// back as a path on the live host — absolute, http, with a host, and so
    /// waved through by `playable` into a catch-up badge whose tap 404s.
    private static func resolve(_ expanded: String, against liveURL: URL, bareToken: BareTokenPolicy) -> URL? {
        if absoluteScheme(of: expanded) != nil {
            return URL(string: expanded)
        }
        if expanded.hasPrefix("//") {
            return URL(string: expanded, relativeTo: liveURL)?.absoluteURL
        }
        if expanded.hasPrefix("?") || expanded.hasPrefix("&") {
            return appending(expanded, to: liveURL)
        }
        switch bareToken {
        case .append:
            return appending(expanded, to: liveURL)
        case .reject:
            guard expanded.hasPrefix("/") || expanded.hasPrefix("./") || expanded.hasPrefix("../") else { return nil }
            return URL(string: expanded, relativeTo: liveURL)?.absoluteURL
        }
    }

    /// The RFC 3986 scheme prefix of `string`, lowercased, or `nil` when it has
    /// none. Not `URL(string:)?.scheme`: that parser rejects strings a template
    /// legitimately expands to (spaces, stray braces) and would then read them
    /// as scheme-less relative paths.
    private static func absoluteScheme(of string: String) -> String? {
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let scheme = string[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        return scheme.lowercased()
    }

    /// Whether `build` would produce a URL for this channel, without keeping
    /// one. **Import-time only** — the sole caller is
    /// `ContentSyncManager+M3U.importLive`, which persists the answer as
    /// `tvArchive`. It costs a full URL construction, so no view, cell body,
    /// focus handler or guide-row snapshot may call it: those read the persisted
    /// `tvArchive`/`catchupTypeRaw` through `PlayableMedia.isCatchupCapable`
    /// instead, which is what keeps SwiftData from faulting per render.
    ///
    /// It has to agree with `build` exactly, which is why it *is* `build`, run
    /// against a throwaway one-hour window.
    static func canBuild(type: CatchupType, source: String?, liveURL: URL) -> Bool {
        let probe = Date(timeIntervalSince1970: 1_700_000_000)
        return build(
            liveURL: liveURL,
            type: type,
            source: source,
            start: probe,
            end: probe.addingTimeInterval(3600),
            now: probe.addingTimeInterval(7200)
        ) != nil
    }

    // MARK: - Dialects

    /// Flussonic serves an archive from the same path as the live stream, with
    /// the window encoded into the filename: `…/video.m3u8` becomes
    /// `…/video-{utc}-{seconds}.m3u8` (the `index.m3u8` and `.ts` spellings work
    /// the same way). Any query the live URL carries — usually a token — is kept.
    ///
    /// Deliberate limitation: a live URL with no filename extension (`…/ch1/mpegts`,
    /// which Flussonic also serves) has nothing to rewrite, and the archive path
    /// for it is not derivable — such a channel is unbuildable and correctly ends
    /// up with no catch-up badge unless the provider ships a `catchup-source`.
    private static func flussonicURL(liveURL: URL, start: Date, duration: Int) -> URL? {
        guard var components = URLComponents(url: liveURL, resolvingAgainstBaseURL: false),
              let live = components.liveContainer,
              !live.stem.isEmpty, live.stem.last != "/"
        else { return nil }
        components.path = "\(live.stem)-\(epoch(start))-\(duration).\(live.format.rawValue)"
        return components.url
    }

    /// `append` glues the expanded template onto the live URL. Providers write
    /// the template as a query fragment (`?utc={utc}&lutc={now}`), so a live URL
    /// that already carries a query has to be merged with `&` instead — and a
    /// template that is a path suffix rather than a query is concatenated as-is.
    private static func appending(_ suffix: String, to liveURL: URL) -> URL? {
        let hasQuery = URLComponents(url: liveURL, resolvingAgainstBaseURL: false)?.query?.isEmpty == false
        let base = liveURL.absoluteString
        let joined: String = switch suffix.first {
        case "?": hasQuery ? base + "&" + suffix.dropFirst() : base + suffix
        case "&": hasQuery ? base + suffix : base + "?" + suffix.dropFirst()
        default: base + suffix
        }
        return URL(string: joined)
    }

    /// An m3u playlist pointed at an Xtream panel: the credentials and the real
    /// provider stream id are in the channel URL path, not on the `Playlist`
    /// (which holds the playlist URL and no credentials) or on the `LiveStream`
    /// (whose `streamId` is an FNV hash for m3u sources). Recover them from
    /// `…/live/{user}/{pass}/{id}.{ext}` — or the `live`-less `…/{user}/{pass}/{id}.{ext}`
    /// variant — and hand off to the Xtream timeshift builder, which is the one
    /// path that legitimately wants minutes and wall clock.
    private static func xcURL(liveURL: URL, start: Date, end: Date) -> URL? {
        guard var components = URLComponents(url: liveURL, resolvingAgainstBaseURL: false) else { return nil }
        // Panels that front their streams with a per-session token carry it as a
        // query on the live URL; dropping it makes the rebuilt timeshift URL a
        // 403. Read it percent-encoded so the token reaches the server verbatim.
        let liveQuery = components.percentEncodedQuery
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return nil }
        let file = parts.removeLast()
        let password = parts.removeLast()
        let username = parts.removeLast()
        guard !username.isEmpty, !password.isEmpty else { return nil }
        if parts.last?.lowercased() == "live" { parts.removeLast() }

        guard let dot = file.lastIndex(of: "."),
              let streamId = Int(file[..<dot])
        else { return nil }
        let ext = file[file.index(after: dot)...].lowercased()
        // The container the provider already hands out for live; the m3u path
        // deliberately never rewrites containers. Anything exotic falls back to
        // MPEG-TS, which is what panels serve catch-up as by default.
        let container = (StreamFormat(rawValue: String(ext)) ?? .tsStream).rawValue

        components.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let base = components.string else { return nil }

        let timeshift = XtreamClient.buildCatchupURL(
            XtreamClient.TimeshiftTarget(
                serverURL: base,
                username: username,
                password: password,
                streamId: streamId,
                container: container,
                // Not an oversight: an m3u `Playlist` stores only the playlist
                // URL, so there is no `serverTimezone` to read here and no
                // request that could learn one — `xc` reaches this builder from
                // an m3u channel only. `.current` is the same device-clock
                // fallback `XtreamClient.buildCatchupURL(for:playlist:…)` uses
                // when a panel does not advertise a timezone, so a wall-clock
                // panel behaves identically whether it was added as m3u or as
                // Xtream. Do not "fix" this to UTC.
                timeZone: .current
            ),
            start: start,
            end: end
        )
        return carryingQuery(liveQuery, onto: timeshift)
    }

    /// Re-attaches the live URL's query to a rebuilt URL, merging with `&` if the
    /// builder produced one of its own. The fragment stays dropped: it is a
    /// client-side anchor, never part of what the panel authorises.
    private static func carryingQuery(_ query: String?, onto url: URL?) -> URL? {
        guard let url else { return nil }
        guard let query, !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + query
        } else {
            components.percentEncodedQuery = query
        }
        return components.url
    }

    // MARK: - Template expansion

    /// Expands a verbatim `catchup-source` template. Templates are stored as the
    /// provider wrote them and expanded here, at play time — expanding at import
    /// time would bake in a stale `now`. Unrecognised placeholders are left
    /// standing rather than treated as an error, so a provider extension we do
    /// not know about still reaches the server intact.
    private static func expand(_ template: String, start: Date, end: Date, now: Date, duration: Int) -> String {
        var result = ""
        var index = template.startIndex
        while let open = template[index...].firstIndex(of: "{"),
              let close = template[open...].firstIndex(of: "}")
        {
            let name = template[template.index(after: open) ..< close].lowercased()
            if let value = placeholderValue(for: name, start: start, end: end, now: now, duration: duration) {
                // `${utc}` is the same placeholder as `{utc}`; swallow the `$`.
                let literalEnd = (open > index && template[template.index(before: open)] == "$")
                    ? template.index(before: open) : open
                result += template[index ..< literalEnd] + value
            } else {
                result += template[index ... close]
            }
            index = template.index(after: close)
        }
        result += template[index...]
        return result
    }

    private static func placeholderValue(
        for name: String,
        start: Date,
        end: Date,
        now: Date,
        duration: Int
    ) -> String? {
        switch name {
        case "utc", "start": epoch(start)
        case "end", "utcend": epoch(end)
        case "duration": String(duration)
        case "offset": String(Int(now.timeIntervalSince(start).rounded()))
        case "now", "lutc", "timestamp": epoch(now)
        default: nil
        }
    }

    private static func epoch(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }
}
