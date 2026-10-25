//
//  MDBListService.swift
//  Lume
//
//  The app-wide coordinator for the MDBList account integration. Owns the OAuth
//  token lifecycle (device-flow connect, refresh, disconnect), exposes
//  connection state for the Settings UI to observe, and provides
//  fire-and-forget watched syncing plus watchlist fetching. Mirrors
//  `SimklService` against MDBList's OAuth and sync endpoints.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles) that don't all have access to the
//  SwiftUI environment. It's still `@Observable`, so views observe
//  `MDBListService.shared` directly.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class MDBListService {
    static let shared = MDBListService()

    /// The connected MDBList username, or nil when not connected.
    private(set) var username: String?

    /// The in-flight device code while the user is approving authorization.
    private(set) var pendingCode: MDBListDeviceCode?

    /// A human-readable failure from the last connect attempt, surfaced in the
    /// Settings UI. Cleared when a new attempt begins.
    private(set) var connectionError: String?

    /// Whether a device-code authorization is currently being polled.
    private(set) var isConnecting = false

    /// Whether a watched-history import is currently running.
    private(set) var isImporting = false

    /// The result of the most recent import, surfaced in the Settings UI.
    private(set) var lastImport: MDBListImportSummary?

    private var tokens: MDBListTokens?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<String?, Never>?

    /// The catalog context the connect flow captured, so the watched-history
    /// import can run the moment the device code is approved.
    private var importContext: ModelContext?

    private let client = MDBListSyncClient.shared

    private init() {}

    /// Whether the build has MDBList OAuth credentials at all. When false the
    /// whole integration is hidden.
    var isConfigured: Bool {
        client.isConfigured
    }

    /// True once a token is held. The username can be missing when `/user`
    /// failed, so it isn't what decides connection.
    var isConnected: Bool {
        tokens != nil
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch: loads the stored
    /// tokens, refreshes them if stale, and fetches the username. Best-effort.
    func restore() async {
        guard isConfigured, let stored = MDBListTokenStore.load() else { return }
        tokens = stored
        guard let accessToken = await validAccessToken() else { return }
        username = try? await client.currentUser(accessToken: accessToken).displayName
    }

    // MARK: - Connect (device flow)

    /// Begins the device-flow connect: requests a code, starts polling, and on
    /// approval imports the account's watched history into the given catalog
    /// context. Passing nil skips the automatic import.
    func connect(into context: ModelContext? = nil) {
        guard isConfigured, !isConnecting else { return }
        connectionError = nil
        isConnecting = true
        importContext = context

        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            await self?.runDeviceFlow()
        }
    }

    /// Cancels an in-progress connect.
    func cancelConnect() {
        pollingTask?.cancel()
        pollingTask = nil
        pendingCode = nil
        isConnecting = false
        importContext = nil
    }

    private func runDeviceFlow() async {
        do {
            let code = try await client.requestDeviceCode()
            pendingCode = code

            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            var interval = TimeInterval(max(code.interval, 1))

            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }

                do {
                    let response = try await client.pollForToken(deviceCode: code.deviceCode)
                    await finishConnect(with: response)
                    return
                } catch MDBListSyncError.authorizationPending {
                    continue
                } catch MDBListSyncError.slowDown {
                    // RFC 8628 §3.5: every slow_down adds 5 s to the interval.
                    interval += 5
                    continue
                } catch let error as URLError where error.code != .cancelled {
                    // A dropped poll is retried on the next tick rather than
                    // abandoning a code the user may be approving right now.
                    continue
                }
            }

            if !Task.isCancelled {
                failConnect(Self.connectFailure(for: MDBListSyncError.codeExpired))
            }
        } catch {
            // A cancelConnect() mid-request throws too; it already reset the
            // state, so only a live attempt reports the failure.
            if !Task.isCancelled {
                failConnect(Self.connectFailure(for: error))
            }
        }
    }

    /// The Settings message for a connect that ended with `error`.
    private static func connectFailure(for error: Error) -> String {
        switch error as? MDBListSyncError {
        case .codeExpired:
            String(localized: "The code expired. Please try connecting again.")
        case .accessDenied:
            String(localized: "Authorization was declined on MDBList.")
        case .invalidClient:
            String(localized: "MDBList rejected this app's credentials.")
        default:
            String(localized: "Couldn't reach MDBList. Check your connection and try again.")
        }
    }

    private func finishConnect(with response: MDBListTokenResponse) async {
        applyTokens(response.tokens())
        username = try? await client.currentUser(accessToken: response.accessToken).displayName
        pendingCode = nil
        isConnecting = false
        connectionError = nil

        if let context = importContext {
            importContext = nil
            await importWatched(into: context)
        }
    }

    private func failConnect(_ message: String) {
        connectionError = message
        pendingCode = nil
        isConnecting = false
        importContext = nil
    }

    // MARK: - Disconnect

    /// Disconnects: revokes the token server-side (best effort) and clears all
    /// local state.
    func disconnect() async {
        pollingTask?.cancel()
        pollingTask = nil
        if let accessToken = tokens?.accessToken {
            try? await client.revokeToken(accessToken)
        }
        clearSession()
    }

    private func clearSession() {
        MDBListTokenStore.clear()
        // Parked watched state belongs to the account that was just signed out.
        MDBListPendingWatchedStore.clearAll()
        tokens = nil
        username = nil
        pendingCode = nil
        isConnecting = false
        lastImport = nil
        importContext = nil
    }

    // MARK: - Watched sync (fire-and-forget)

    /// Syncs a movie's watched state to MDBList. Captures the TMDB id and title
    /// up front so the model never crosses an actor boundary. No-ops when not
    /// connected or the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard isConnected, let tmdbID = movie.tmdbId else { return }
        syncHistory(.movie(tmdbID: tmdbID, title: movie.name), add: watched)
    }

    /// Syncs an episode's watched state to MDBList using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard isConnected, let series = episode.series, let showTMDBID = series.tmdbId else { return }
        let items = MDBListSyncItems.episode(
            showTMDBID: showTMDBID,
            showTitle: series.name,
            season: episode.seasonNum,
            episode: episode.episodeNum
        )
        syncHistory(items, add: watched)
    }

    private func syncHistory(_ items: MDBListSyncItems, add: Bool) {
        Task { [weak self] in
            guard let self, let accessToken = await validAccessToken() else { return }
            do {
                if add {
                    try await client.addToHistory(items, accessToken: accessToken)
                } else {
                    try await client.removeFromHistory(items, accessToken: accessToken)
                }
            } catch {
                // Best-effort; a failed sync shouldn't disrupt playback or the UI.
            }
        }
    }

    // MARK: - Watchlist

    /// The user's watchlist, most recently added first. Returns an empty array
    /// when not connected or on error — the Home row simply hides.
    func fetchWatchlist() async -> [MDBListWatchlistEntry] {
        guard let accessToken = await validAccessToken(),
              let entries = try? await client.watchlist(accessToken: accessToken)
        else { return [] }
        return Self.newestFirst(entries)
    }

    /// Newest addition first, undated entries last, otherwise in server order.
    nonisolated static func newestFirst(_ entries: [MDBListWatchlistEntry]) -> [MDBListWatchlistEntry] {
        entries.enumerated()
            .sorted { lhs, rhs in
                let lhsDate = lhs.element.addedAt ?? .distantPast
                let rhsDate = rhs.element.addedAt ?? .distantPast
                return lhsDate == rhsDate ? lhs.offset < rhs.offset : lhsDate > rhsDate
            }
            .map(\.element)
    }

    // MARK: - Watched import

    /// Imports the user's MDBList watched history into the local catalog,
    /// marking matching movies and episodes as watched. Writes through a
    /// context of its own on `context`'s container, off the main actor; the
    /// iCloud reconciler then mirrors it to the user's other devices. No-ops
    /// when not connected or an import is already running.
    func importWatched(into context: ModelContext) async {
        guard isConnected, !isImporting else { return }
        isImporting = true
        lastImport = nil
        defer { isImporting = false }

        guard let accessToken = await validAccessToken() else {
            lastImport = .failure
            return
        }
        do {
            let history = try await client.watchedHistory(accessToken: accessToken)
            lastImport = await Self.applyImport(history: history, container: context.container)
        } catch {
            lastImport = .failure
        }
    }

    /// Off the main actor for the same reason as `SimklService.applyImport`.
    @concurrent
    private static func applyImport(history: MDBListWatchedHistory, container: ModelContainer) async -> MDBListImportSummary {
        MDBListWatchedImporter.apply(history: history, in: ModelContext(container))
    }

    // MARK: - Tokens

    /// Returns a usable access token, refreshing first if it's stale. Coalesces
    /// concurrent refreshes into a single request.
    private func validAccessToken() async -> String? {
        guard let current = tokens else { return nil }
        if !current.needsRefresh {
            return current.accessToken
        }

        if let refreshTask {
            return await refreshTask.value
        }

        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            do {
                let response = try await client.refreshToken(current.refreshToken)
                let refreshed = response.tokens(previousRefreshToken: current.refreshToken)
                applyTokens(refreshed)
                return refreshed.accessToken
            } catch MDBListSyncError.server(400), MDBListSyncError.notAuthenticated, MDBListSyncError.invalidClient {
                // The refresh token itself was refused — drop the session so the
                // UI prompts a reconnect rather than retrying forever.
                clearSession()
                return nil
            } catch {
                // Offline or a server hiccup: keep the session and use the
                // current token while it's still valid; the next call retries.
                return current.expiryDate > Date() ? current.accessToken : nil
            }
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func applyTokens(_ newTokens: MDBListTokens) {
        tokens = newTokens
        MDBListTokenStore.save(newTokens)
    }
}
