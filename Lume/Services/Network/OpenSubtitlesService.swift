//
//  OpenSubtitlesService.swift
//  Lume
//
//  App-wide coordinator for the OpenSubtitles integration. Owns the user
//  session (sign in / restore / sign out), remembers the viewer's preferred
//  subtitle languages, and turns a picked search result into a local file the
//  playback engines can side-load.
//
//  A shared singleton because the player overlays reach it from four different
//  engine views that have no common environment injection point, and the
//  Settings pane observes the same instance.
//

import Foundation
import OSLog
import SwiftUI

@MainActor
@Observable
final class OpenSubtitlesService {
    static let shared = OpenSubtitlesService()

    /// The signed-in account name, or nil when the user hasn't signed in.
    private(set) var username: String?

    /// Downloads left in today's allowance, as last reported by `/download`.
    /// `nil` until a download has been made this session.
    private(set) var remainingDownloads: Int?

    /// The account's daily download allowance, from the sign-in response.
    private(set) var allowedDownloads: Int?

    /// A human-readable failure from the last sign-in attempt, surfaced in the
    /// Settings pane. Cleared when a new attempt begins.
    private(set) var signInError: String?

    private(set) var isSigningIn = false

    /// The languages the search sheet asks for, persisted across launches.
    /// Defaults to the app's own language, which is the one the viewer reads.
    var preferredLanguages: [String] {
        didSet {
            guard preferredLanguages != oldValue else { return }
            UserDefaults.standard.set(preferredLanguages, forKey: Self.languagesKey)
        }
    }

    private var session: OpenSubtitlesSession?
    private var cachedLanguages: [OpenSubtitlesLanguage] = []
    private let client = OpenSubtitlesClient.shared

    static let languagesKey = "openSubtitlesPreferredLanguages"

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.languagesKey)
        preferredLanguages = stored ?? Self.defaultLanguages()
    }

    /// Whether the build carries an API key at all. When false the whole
    /// integration hides rather than surfacing errors the user can't act on.
    var isConfigured: Bool {
        client.isConfigured
    }

    var isSignedIn: Bool {
        session != nil
    }

    /// Whether the in-player search should be offered for `media`. Live channels
    /// are excluded: OpenSubtitles indexes films and episodes, and a live stream
    /// has neither an id nor a stable title to match on.
    static func supportsSearch(for media: PlayableMedia) -> Bool {
        shared.isConfigured && !media.isLive
    }

    /// The app's UI language as an OpenSubtitles language code. OpenSubtitles
    /// keys on the bare language part (`de`, `pt-br`), so a full identifier like
    /// `de-DE` is trimmed back to its language code.
    static func defaultLanguages() -> [String] {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = Locale(identifier: preferred).language.languageCode?.identifier ?? "en"
        return [code]
    }

    // MARK: - Session

    /// Restores a previously signed-in session at launch. Cheap — a keychain
    /// read, no network.
    func restore() {
        guard isConfigured else { return }
        session = OpenSubtitlesSessionStore.load()
        username = session?.username
        allowedDownloads = session?.allowedDownloads
    }

    func signIn(username enteredUsername: String, password: String) async {
        guard isConfigured, !isSigningIn else { return }
        let trimmed = enteredUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return }

        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }

        do {
            var newSession = try await client.login(username: trimmed, password: password)
            newSession.password = password
            adopt(newSession)
            remainingDownloads = nil
        } catch let error as OpenSubtitlesError {
            signInError = String(localized: error.message)
        } catch {
            signInError = error.localizedDescription
        }
    }

    func signOut() async {
        if let session {
            // Best-effort: the local session is dropped regardless.
            try? await client.logout(session: session)
        }
        endSession()
        signInError = nil
        OnlineSubtitleCache.clear()
    }

    private func adopt(_ newSession: OpenSubtitlesSession) {
        OpenSubtitlesSessionStore.save(newSession)
        session = newSession
        username = newSession.username
        allowedDownloads = newSession.allowedDownloads
    }

    private func endSession() {
        OpenSubtitlesSessionStore.clear()
        session = nil
        username = nil
        allowedDownloads = nil
        remainingDownloads = nil
    }

    /// Runs `request` with the current session. An expired token is renewed
    /// once from the stored credentials; when that isn't possible the session
    /// is dropped, so the UI stops claiming a sign-in the server no longer
    /// honours.
    private func withSession<T>(_ request: (OpenSubtitlesSession) async throws -> T) async throws -> T {
        guard let session else { throw OpenSubtitlesError.notAuthenticated }
        do {
            let result = try await Self.performRenewing(
                session: session,
                login: { try await self.client.login(username: $0, password: $1) },
                request: request
            )
            if let renewed = result.renewed {
                adopt(renewed)
            }
            return result.value
        } catch OpenSubtitlesError.notAuthenticated {
            endSession()
            throw OpenSubtitlesError.notAuthenticated
        }
    }

    /// `request` against `session`, retried once on a fresh token when the
    /// server rejects the stored one. Returns the renewed session, if any, for
    /// the caller to persist. Throws `.notAuthenticated` when the token can't
    /// be renewed: no stored password, or the account no longer accepts it.
    static func performRenewing<T>(
        session: OpenSubtitlesSession,
        login: (String, String) async throws -> OpenSubtitlesSession,
        request: (OpenSubtitlesSession) async throws -> T
    ) async throws -> (value: T, renewed: OpenSubtitlesSession?) {
        do {
            return try await (request(session), nil)
        } catch OpenSubtitlesError.notAuthenticated {
            guard let password = session.password else { throw OpenSubtitlesError.notAuthenticated }
            var renewed: OpenSubtitlesSession
            do {
                renewed = try await login(session.username, password)
            } catch OpenSubtitlesError.invalidCredentials {
                throw OpenSubtitlesError.notAuthenticated
            }
            renewed.password = password
            return try await (request(renewed), renewed)
        }
    }

    // MARK: - Search

    /// Subtitle candidates for `query` in `preferredLanguages`, best-downloaded
    /// first. Works signed out — only downloading needs an account.
    func search(_ query: OpenSubtitlesQuery) async throws -> [OnlineSubtitle] {
        var query = query
        query.languages = preferredLanguages
        let results: [OnlineSubtitle]
        if session == nil {
            results = try await client.search(query)
        } else {
            do {
                results = try await withSession { try await self.client.search(query, host: $0.host, token: $0.token) }
            } catch OpenSubtitlesError.notAuthenticated {
                // Searching doesn't need an account, so a session that couldn't
                // be renewed falls back to an anonymous search.
                results = try await client.search(query)
            }
        }
        return results.sorted { $0.downloadCount > $1.downloadCount }
    }

    /// The full language list for the search sheet's filter, fetched once per
    /// app run.
    func languages() async -> [OpenSubtitlesLanguage] {
        if !cachedLanguages.isEmpty {
            return cachedLanguages
        }
        cachedLanguages = await (try? client.languages(host: host)) ?? []
        return cachedLanguages
    }

    // MARK: - Download

    /// Downloads `subtitle` and returns the local file the engines load. Cached
    /// on disk, so re-picking the same track inside a session costs nothing
    /// against the daily allowance.
    func download(_ subtitle: OnlineSubtitle) async throws -> URL {
        if let cached = OnlineSubtitleCache.cachedFile(for: subtitle) {
            return cached
        }
        let download = try await withSession { try await self.client.downloadLink(for: subtitle, session: $0) }
        let data = try await client.fetch(download)
        remainingDownloads = download.remainingDownloads
        Logger.player.info("OpenSubtitles: downloaded subtitle, \(download.remainingDownloads) left today")
        return try OnlineSubtitleCache.store(data, for: subtitle)
    }

    private var host: String {
        session?.host ?? OpenSubtitlesClient.defaultHost
    }
}

// MARK: - On-disk cache

/// Where downloaded subtitle files live: a folder in Caches, so the system can
/// evict them under pressure without stranding the app. Files are named by
/// subtitle id, which makes a re-pick of the same track a cache hit instead of
/// another download against the daily quota.
enum OnlineSubtitleCache {
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("OpenSubtitles", isDirectory: true)
    }

    static func fileURL(for subtitle: OnlineSubtitle) -> URL {
        // The engines pick their parser from the path extension, so the `.srt`
        // suffix is load-bearing — `sub_format: "srt"` guarantees the content.
        directory.appendingPathComponent("\(subtitle.id).\(subtitle.languageCode).srt")
    }

    static func cachedFile(for subtitle: OnlineSubtitle) -> URL? {
        let url = fileURL(for: subtitle)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func store(_ data: Data, for subtitle: OnlineSubtitle) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: subtitle)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
