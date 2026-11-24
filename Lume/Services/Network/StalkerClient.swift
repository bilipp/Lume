//
//  StalkerClient.swift
//  Lume
//
//  Stalker (Ministra) portal API client. Authenticates by MAC address via the
//  handshake → token flow, fetches the live / VOD / series catalog, and resolves
//  short-lived play URLs on demand through `create_link`. Mirrors the shape and
//  retry behaviour of `XtreamClient`.
//

import Foundation
import OSLog
import Synchronization

// MARK: - StalkerClient

/// Nonisolated for the same reason as `XtreamClient`: a MainActor client decoded
/// `get_all_channels` and every page of a thousands-of-pages catalog walk on the
/// main thread. Its work now runs on the caller (the sync actor, or the walk's
/// child tasks) and each decode runs off any actor.
final nonisolated class StalkerClient: Sendable {
    let configuration: Configuration
    let session: URLSession

    nonisolated init(configuration: Configuration, urlSession: URLSession? = nil) {
        self.configuration = configuration
        session = urlSession ?? Self.session(timeout: configuration.timeout)
    }

    /// Opaque key covering the complete effective authentication configuration.
    private var sessionKey: String {
        configuration.sessionKey
    }

    // MARK: - Session / handshake

    /// Returns a profile-validated session, joining an in-flight handshake.
    private func authorizedSession() async throws -> StalkerSessionStore.Session {
        guard !configuration.identityUnavailable else { throw StalkerIdentityError.localIdentityRequired }
        try configuration.identity.validate()
        try Task.checkCancellation()
        let session = try await StalkerSessionStore.shared.authorize(sessionKey) { try await self.handshake() }
        try Task.checkCancellation()
        return session
    }

    /// Performs the Stalker handshake against each candidate endpoint until one
    /// returns a token, then primes the session with `get_profile` (some portals
    /// only activate the token once the profile is fetched). When every
    /// candidate fails, follows the pasted URL's redirects and retries against
    /// wherever it lands — providers hand out a stable redirector domain whose
    /// 301s drop the path (`/server/load.php?…` → `https://other-host/`), so the
    /// real portal is only reachable by loading the page like a browser would.
    private func handshake() async throws -> StalkerSessionStore.Session {
        let endpoints = Self.candidateEndpoints(for: configuration.portalURL)
        guard !endpoints.isEmpty else { throw StalkerError.invalidURL }

        var lastError: Error = StalkerError.handshakeFailed
        if let session = try await handshake(trying: endpoints, lastError: &lastError) {
            return session
        }
        guard let discovered = await redirectedPortalURL() else { throw lastError }
        let retry = Self.candidateEndpoints(for: discovered.absoluteString).filter { !endpoints.contains($0) }
        guard !retry.isEmpty else { throw lastError }
        Logger.network.info("Stalker portal redirected; retrying discovered endpoint")
        if let session = try await handshake(trying: retry, lastError: &lastError) {
            return session
        }
        throw lastError
    }

    private func handshake(
        trying endpoints: [URL],
        lastError: inout Error
    ) async throws -> StalkerSessionStore.Session? {
        for (index, endpoint) in endpoints.enumerated() {
            // Bail immediately if a caller deadline (e.g. the add-playlist
            // connection-test timeout) cancelled us, rather than racing through
            // the remaining endpoints.
            try Task.checkCancellation()
            do {
                let url = appendingQuery(to: endpoint, [
                    URLQueryItem(name: "type", value: "stb"),
                    URLQueryItem(name: "action", value: "handshake"),
                    URLQueryItem(name: "token", value: ""),
                    URLQueryItem(name: "JsHttpRequest", value: "1-xml")
                ])
                let envelope: StalkerEnvelope<StalkerHandshake> = try await perform(url: url, token: nil)
                guard let token = envelope.js.token, !token.isEmpty else {
                    lastError = StalkerError.handshakeFailed
                    continue
                }
                let session = StalkerSessionStore.Session(token: token, endpoint: endpoint)
                // A token is not authentication. Never cache or probe another
                // endpoint after this endpoint has explicitly refused the profile.
                do {
                    let profile = try await checkedProfile(using: session)
                    return StalkerSessionStore.Session(token: token, endpoint: endpoint, profile: profile)
                } catch {
                    Logger.network.error("Stalker profile authentication failed — \(Self.safeError(error))")
                    throw ProfileFailure(underlying: error)
                }
            } catch {
                if let failure = error as? ProfileFailure { throw failure.underlying }
                lastError = error
                // What each miss returned tells a wrong path from a blocked device.
                let shape = NetworkDiagnostics.shape(of: endpoint.absoluteString)
                let returned = lastResponseFingerprint ?? "no response"
                Logger.network.info(
                    "Stalker handshake candidate \(index + 1)/\(endpoints.count) [\(shape)] failed — \(Self.safeError(error)) — \(returned)"
                )
                continue
            }
        }
        return nil
    }

    /// What the most recent failed `perform` got back, for the failure logs.
    private var lastResponseFingerprint: String? {
        responseFingerprint.withLock { $0 }
    }

    /// Written by concurrent page fetches during a walk; last writer wins, which
    /// is all a failure log needs.
    private let responseFingerprint = Mutex<String?>(nil)

    // MARK: - Request plumbing

    private func appendingQuery(to endpoint: URL, _ items: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        components.queryItems = (components.queryItems ?? []) + items
        // PHP form-query parsers treat a literal "+" as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? endpoint
    }

    private static let maxAttempts = 3

    private struct ProfileFailure: Error {
        let underlying: Error
    }

    private static func safeError(_ error: Error) -> String {
        (error as? StalkerError)?.logDescription ?? "request failed"
    }

    /// Issues an authorized request for the given action, retrying once on an
    /// auth failure with a fresh handshake, and with backoff on transient
    /// network errors. Not `private`: extensions such as `StalkerClient+EPG.swift`
    /// call it directly.
    func request<T: Decodable & Sendable>(
        type: String,
        action: String,
        extraQuery: [URLQueryItem] = []
    ) async throws -> T {
        var refreshedAuth = false
        var attempt = 0
        while true {
            attempt += 1
            let session = try await authorizedSession()
            let query = [
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "action", value: action)
            ] + extraQuery + [URLQueryItem(name: "JsHttpRequest", value: "1-xml")]
            let url = appendingQuery(to: session.endpoint, query)
            do {
                return try await perform(url: url, token: session.token)
            } catch let error as StalkerError {
                if error.isAuthFailure, !refreshedAuth {
                    refreshedAuth = true
                    await StalkerSessionStore.shared.invalidate(sessionKey, matching: session.id)
                    continue
                }
                guard error.isRetriable, attempt < Self.maxAttempts else {
                    // Only here, not in `perform`: the handshake's endpoint
                    // probing decodes HTML from the wrong candidates by design.
                    let returned = lastResponseFingerprint ?? "no response"
                    Logger.network.error(
                        "Stalker: \(type, privacy: .public) \(action, privacy: .public) failed — \(error.logDescription) — \(returned)"
                    )
                    throw error
                }
                let delay = pow(2.0, Double(attempt))
                Logger.network.warning(
                    "Stalker request failed (\(error.logDescription)); retry \(attempt)/\(Self.maxAttempts - 1) in \(delay)s"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// A single request attempt. Sets the MAC cookie, bearer token and MAG
    /// headers the portal requires, and maps transport/HTTP failures onto
    /// `StalkerError`.
    private func perform<T: Decodable & Sendable>(url: URL, token: String?) async throws -> T {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(stalkerUserAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("Model: MAG250; Link: WiFi", forHTTPHeaderField: "X-User-Agent")
        urlRequest.setValue(Self.referer(for: url), forHTTPHeaderField: "Referer")
        urlRequest.setValue(
            "mac=\(configuration.macAddress); stb_lang=en; timezone=Europe/London",
            forHTTPHeaderField: "Cookie"
        )
        // Verified IPTVnator transport contract: SN is a header on portal API
        // requests; sn/device ids/signatures are not blanket query parameters.
        if let serial = configuration.identity.serialNumber {
            urlRequest.setValue(serial, forHTTPHeaderField: "SN")
        }
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        responseFingerprint.withLock { $0 = nil }
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw StalkerError.networkError(error)
        }
        do {
            return try await Self.decodeValidatedOffActor(T.self, response: response, data: data)
        } catch {
            // Metadata only; a provider can echo identifiers in any body.
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let fingerprint = "HTTP \(code), \(data.count) bytes"
            responseFingerprint.withLock { $0 = fingerprint }
            throw error
        }
    }

    // MARK: - Profile

    private func getProfile(using session: StalkerSessionStore.Session, secondStep: Bool = false) async throws -> StalkerProfile {
        let url = appendingQuery(to: session.endpoint, [
            URLQueryItem(name: "type", value: "stb"),
            URLQueryItem(name: "action", value: "get_profile"),
            URLQueryItem(name: "JsHttpRequest", value: "1-xml")
        ] + configuration.identity.profileQuery + (secondStep ? [URLQueryItem(name: "auth_second_step", value: "1")] : []))
        let envelope: StalkerEnvelope<StalkerProfile> = try await perform(url: url, token: session.token)
        return envelope.js
    }

    private func checkedProfile(using session: StalkerSessionStore.Session) async throws -> StalkerProfile {
        var profile = try await getProfile(using: session)
        if profile.status == "2" {
            guard !configuration.username.isEmpty, !configuration.password.isEmpty else { throw StalkerError.authenticationFailed }
            let url = appendingQuery(to: session.endpoint, [
                URLQueryItem(name: "type", value: "stb"),
                URLQueryItem(name: "action", value: "do_auth"),
                URLQueryItem(name: "login", value: configuration.username),
                URLQueryItem(name: "password", value: configuration.password),
                URLQueryItem(name: "JsHttpRequest", value: "1-xml")
            ] + configuration.identity.authQuery)
            let result: StalkerEnvelope<Bool> = try await perform(url: url, token: session.token)
            guard result.js else { throw StalkerError.authenticationFailed }
            profile = try await getProfile(using: session, secondStep: true)
            guard profile.status != "2" else { throw StalkerError.authenticationFailed }
        }
        guard !profile.isBlocked else { throw StalkerError.deviceBlocked }
        guard profile.hasProfileData else { throw StalkerError.invalidResponse }
        return profile
    }

    /// Validates the portal connection by handshaking and reading the profile.
    /// Used by the add-playlist flow as the connection test.
    /// A refusal is reported without quoting the provider's private message.
    func authenticate() async throws -> StalkerProfile {
        let session = try await authorizedSession()
        if let profile = session.profile { return profile }
        return try await checkedProfile(using: session)
    }

    // MARK: - Live TV (itv)

    func getLiveGenres() async throws -> [StalkerCategory] {
        let envelope: StalkerEnvelope<[StalkerCategory]> = try await request(type: "itv", action: "get_genres")
        return envelope.js
    }

    /// All live channels in one call. Returns the full channel list; the genre id
    /// on each channel maps it to a genre fetched via `getLiveGenres`.
    func getAllChannels() async throws -> [StalkerChannel] {
        let envelope: StalkerEnvelope<StalkerPage<StalkerChannel>> = try await request(
            type: "itv",
            action: "get_all_channels"
        )
        return envelope.js.data
    }

    // MARK: - VOD (vod) / Series (series)

    func getCategories(type: String) async throws -> [StalkerCategory] {
        let envelope: StalkerEnvelope<[StalkerCategory]> = try await request(type: type, action: "get_categories")
        return envelope.js
    }

    /// A single page of an ordered list for `type` (`vod` or `series`) within a
    /// category. Returns the page items and the reported total (for pagination).
    /// `search`, when set, filters portal-side — the middleware matches it
    /// against name, original name, actors, director and year — which is how a
    /// Stalker catalog is searched without a local index.
    func getOrderedList(
        type: String,
        categoryId: String,
        page: Int,
        movieId: String? = nil,
        search: String? = nil
    ) async throws -> (items: [StalkerVODItem], totalItems: Int?, pageSize: Int?) {
        var query = [
            URLQueryItem(name: "category", value: categoryId),
            URLQueryItem(name: "genre", value: categoryId),
            URLQueryItem(name: "sortby", value: "added"),
            URLQueryItem(name: "p", value: String(page))
        ]
        if let movieId {
            query.append(URLQueryItem(name: "movie_id", value: movieId))
        }
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        let envelope: StalkerEnvelope<StalkerPage<StalkerVODItem>> = try await request(
            type: type,
            action: "get_ordered_list",
            extraQuery: query
        )
        return (envelope.js.data, envelope.js.totalItems, envelope.js.maxPageItems)
    }

    /// The result of walking an ordered list. `complete` is `false` when the
    /// walk was truncated — by the `maxItems` cap or a page failing mid-walk —
    /// in which case `items` is a valid prefix of the catalog, not all of it.
    nonisolated struct OrderedListWalk {
        let items: [StalkerVODItem]
        let complete: Bool
    }

    /// Identifies one ordered list (`get_ordered_list` target) across the
    /// pages of a walk.
    private nonisolated struct OrderedListTarget {
        let type: String
        let categoryId: String
        let movieId: String?
        let search: String?
    }

    /// Walks every page of an ordered list and returns the combined items.
    /// `maxItems` caps the walk so a runaway `total_items` can't loop forever.
    /// `onPage` reports (items fetched so far, reported total) after each page
    /// so long walks can surface sync progress.
    ///
    /// The first page is fetched alone (it validates the session and reports
    /// the totals that size the walk); the rest are fetched `walkConcurrency`
    /// pages at a time — the portal's fixed ~14-item page size makes a large
    /// catalog thousands of ~2s requests, and only the parallelism keeps that
    /// inside a usable sync duration.
    func getAllOrderedItems(
        type: String,
        categoryId: String,
        movieId: String? = nil,
        search: String? = nil,
        maxItems: Int = 20000,
        onPage: ((Int, Int?) async -> Void)? = nil
    ) async throws -> OrderedListWalk {
        let target = OrderedListTarget(type: type, categoryId: categoryId, movieId: movieId, search: search)
        let first = try await getOrderedList(type: type, categoryId: categoryId, page: 1, movieId: movieId, search: search)
        let pageSize = first.pageSize.flatMap { $0 > 0 ? $0 : nil } ?? 14
        await onPage?(first.items.count, first.totalItems)
        if first.items.isEmpty {
            return OrderedListWalk(items: first.items, complete: true)
        }
        guard let total = first.totalItems else {
            // No reported total (rare): fall back to paging serially until a
            // short page.
            return try await sequentialWalkTail(
                target, maxItems: maxItems, pageSize: pageSize, seed: first.items, onPage: onPage
            )
        }

        let lastPage = max(1, Int(ceil(Double(total) / Double(pageSize))))
        let lastFetchedPage = min(lastPage, max(1, Int(ceil(Double(maxItems) / Double(pageSize)))))
        guard lastFetchedPage >= 2 else {
            return OrderedListWalk(items: first.items, complete: lastFetchedPage >= lastPage)
        }
        let tail = try await parallelWalkTail(
            target, pages: 2 ... lastFetchedPage, total: total, seedCount: first.items.count, onPage: onPage
        )
        return OrderedListWalk(
            items: first.items + tail.items,
            complete: tail.complete && lastFetchedPage >= lastPage
        )
    }

    /// Fetches pages `pages` of an ordered list, `walkConcurrency` at a time,
    /// and reassembles them in page order. A page failing mid-walk (after
    /// `request`'s own retries) doesn't discard the pages already fetched — a
    /// large catalog is hundreds of requests deep at this point — it just
    /// marks the walk incomplete.
    private func parallelWalkTail(
        _ target: OrderedListTarget,
        pages pageRange: ClosedRange<Int>,
        total: Int,
        seedCount: Int,
        onPage: ((Int, Int?) async -> Void)?
    ) async throws -> OrderedListWalk {
        var pages: [Int: [StalkerVODItem]] = [:]
        var fetched = seedCount
        var failed = false
        do {
            try await withThrowingTaskGroup(of: (page: Int, items: [StalkerVODItem]).self) { group in
                var nextPage = pageRange.lowerBound
                func addNextPage() {
                    let page = nextPage
                    nextPage += 1
                    group.addTask {
                        let result = try await self.getOrderedList(
                            type: target.type, categoryId: target.categoryId,
                            page: page, movieId: target.movieId, search: target.search
                        )
                        return (page: page, items: result.items)
                    }
                }
                while nextPage <= pageRange.upperBound,
                      nextPage < pageRange.lowerBound + Self.walkConcurrency
                {
                    addNextPage()
                }
                while let result = try await group.next() {
                    pages[result.page] = result.items
                    fetched += result.items.count
                    await onPage?(fetched, total)
                    if nextPage <= pageRange.upperBound {
                        addNextPage()
                    }
                }
            }
        } catch {
            // Cancellation must abort the sync, not masquerade as a
            // partially-walked catalog.
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            let count = fetched
            let type = target.type
            Logger.network.warning("Stalker: \(type) list page failed mid-walk; keeping \(count) items")
            failed = true
        }
        var items: [StalkerVODItem] = []
        for page in pages.keys.sorted() {
            items.append(contentsOf: pages[page] ?? [])
        }
        return OrderedListWalk(items: items, complete: !failed)
    }

    /// Serial page walk used when the portal doesn't report `total_items`, so
    /// the end of the list is only discoverable by hitting a short page.
    private func sequentialWalkTail(
        _ target: OrderedListTarget,
        maxItems: Int,
        pageSize: Int,
        seed: [StalkerVODItem],
        onPage: ((Int, Int?) async -> Void)?
    ) async throws -> OrderedListWalk {
        var all = seed
        var page = 2
        while all.count < maxItems {
            try Task.checkCancellation()
            let result: (items: [StalkerVODItem], totalItems: Int?, pageSize: Int?)
            do {
                result = try await getOrderedList(
                    type: target.type, categoryId: target.categoryId,
                    page: page, movieId: target.movieId, search: target.search
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let count = all.count
                let type = target.type
                Logger.network.warning("Stalker: \(type) list page \(page) failed; keeping \(count) items")
                return OrderedListWalk(items: all, complete: false)
            }
            all.append(contentsOf: result.items)
            await onPage?(all.count, nil)
            if result.items.count < pageSize {
                return OrderedListWalk(items: all, complete: true)
            }
            page += 1
        }
        return OrderedListWalk(items: all, complete: false)
    }

    // MARK: - Stream resolution

    /// Resolves a `cmd` into a short-lived playable URL via `create_link`.
    func resolveStreamURL(type: StalkerLink.LinkType, cmd: String) async throws -> URL {
        let envelope: StalkerEnvelope<StalkerCreateLink> = try await request(
            type: type.rawValue,
            action: "create_link",
            extraQuery: [URLQueryItem(name: "cmd", value: cmd)] + StalkerLink.forwardedQueryItems(from: cmd)
        )
        guard let rawCmd = envelope.js.cmd, let url = StalkerLink.resolvedURL(from: rawCmd) else {
            throw StalkerError.noStreamURL
        }
        // An empty `stream=` means the portal minted a link without a channel
        // id — unplayable (the server 405s). Fail here rather than letting
        // every engine burn through it.
        let streamId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "stream" }?.value
        if let streamId, streamId.isEmpty {
            throw StalkerError.noStreamURL
        }
        return url
    }
}

// MARK: - Endpoint resolution

extension StalkerClient {
    /// The portal's `/c/` page on the host actually being called, used for the
    /// `Referer` header — after a redirect-discovered handshake that is not the
    /// host the user pasted.
    private nonisolated static func referer(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.path = components.path.contains("/stalker_portal/") ? "/stalker_portal/c/" : "/c/"
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Loads the pasted portal URL with redirects followed and returns where it
    /// ended up, or `nil` when it didn't redirect anywhere new.
    private func redirectedPortalURL() async -> URL? {
        let raw = configuration.portalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pasted = URL(string: raw) else { return nil }
        var request = URLRequest(url: pasted)
        request.setValue(stalkerUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let final = response.url,
              final.host != pasted.host || final.path != pasted.path
        else { return nil }
        return final
    }
}
