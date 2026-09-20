//
//  SimklService.swift
//  Lume
//
//  The app-wide coordinator for the Simkl integration. Owns the OAuth token
//  lifecycle (device-flow connect, refresh, disconnect), exposes connection
//  state for the Settings UI to observe, and provides fire-and-forget watched
//  syncing. Mirrors `TraktService` against the Simkl AUTH V2 API.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles, model methods) that don't all
//  have access to the SwiftUI environment. It's still `@Observable`, so views
//  observe `SimklService.shared` directly.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SimklService {
    static let shared = SimklService()

    /// The connected Simkl username, or nil when not connected.
    private(set) var username: String?

    /// The in-flight device code while the user is approving authorization.
    private(set) var pendingCode: SimklDeviceCode?

    /// A human-readable failure from the last connect attempt, surfaced in the
    /// Settings UI. Cleared when a new attempt begins.
    private(set) var connectionError: String?

    /// Whether a device-code authorization is currently being polled.
    private(set) var isConnecting = false

    /// Whether a watched-history import is currently running.
    private(set) var isImporting = false

    /// The result of the most recent import, surfaced in the Settings UI.
    /// Cleared when a new import begins.
    private(set) var lastImport: SimklImportSummary?

    private var tokens: SimklTokens?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<String?, Never>?

    /// The catalog context the connect flow captured, so the watched-history
    /// import can run the moment the device code is approved.
    private var importContext: ModelContext?

    private let client = SimklClient.shared

    private init() {}

    /// Whether the build has Simkl credentials at all. When false the whole
    /// integration is hidden.
    var isConfigured: Bool {
        client.isConfigured
    }

    var isConnected: Bool {
        username != nil
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch: loads the stored
    /// tokens, refreshes them if stale, and fetches the username. Best-effort.
    func restore() async {
        guard isConfigured, let stored = SimklTokenStore.load() else { return }
        tokens = stored
        guard let accessToken = await validAccessToken() else {
            // Refresh failed (revoked/expired) — drop the dead session quietly.
            await disconnect()
            return
        }
        username = try? await client.currentUser(accessToken: accessToken).name
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

            // A declined code is indistinguishable from an untouched one —
            // Simkl records nothing on decline — so the `expiresIn` deadline is
            // the only way this loop ends for a user who says no.
            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }

                do {
                    let response = try await client.pollForToken(deviceCode: code.deviceCode)
                    await finishConnect(with: response)
                    return
                } catch SimklError.authorizationPending {
                    continue
                } catch SimklError.slowDown {
                    // Simkl asks for a flat +5 s on slow-down; retrying at the
                    // old cadence re-arms their poll window and locks the loop
                    // out until the code expires.
                    interval += 5
                    continue
                } catch SimklError.codeExpired {
                    failConnect("The code expired. Please try connecting again.")
                    return
                } catch SimklError.invalidClient {
                    failConnect("Simkl rejected this app's credentials.")
                    return
                }
            }

            if !Task.isCancelled {
                failConnect("The code expired. Please try connecting again.")
            }
        } catch is CancellationError {
            // Cancelled via cancelConnect() — state already reset there.
        } catch {
            failConnect("Couldn't reach Simkl. Check your connection and try again.")
        }
    }

    private func finishConnect(with response: SimklTokenResponse) async {
        applyTokens(response.tokens)
        username = try? await client.currentUser(accessToken: response.accessToken).name
        pendingCode = nil
        isConnecting = false
        connectionError = nil

        // The issue's contract: the account's watched history imports on
        // connect, not only on demand. Runs on the context the connect call
        // captured; the manual re-import below stays available for later.
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
        SimklTokenStore.clear()
        // Parked watched state belongs to the account that was just signed out.
        SimklPendingWatchedStore.clearAll()
        tokens = nil
        username = nil
        pendingCode = nil
        isConnecting = false
        lastImport = nil
        importContext = nil
    }

    // MARK: - Watched sync (fire-and-forget)

    /// Syncs a movie's watched state to Simkl. Captures the TMDB id and title
    /// up front so the model never crosses an actor boundary. No-ops when not
    /// connected or the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard isConnected, let tmdbID = movie.tmdbId else { return }
        let items = SimklSyncItems.movie(tmdbID: tmdbID, title: movie.name)
        syncHistory(items, add: watched)
    }

    /// Syncs an episode's watched state to Simkl using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard isConnected, let series = episode.series, let showTMDBID = series.tmdbId else { return }
        let items = SimklSyncItems.episode(
            showTMDBID: showTMDBID,
            showTitle: series.name,
            season: episode.seasonNum,
            episode: episode.episodeNum
        )
        syncHistory(items, add: watched)
    }

    private func syncHistory(_ items: SimklSyncItems, add: Bool) {
        Task { [weak self] in
            guard let self, let accessToken = await validAccessToken() else { return }
            do {
                if add {
                    try await client.addToHistory(items, accessToken: accessToken)
                } else {
                    try await client.removeFromHistory(items, accessToken: accessToken)
                }
            } catch {
                // Scrobbling is best-effort; a failed sync shouldn't disrupt
                // playback or the UI.
            }
        }
    }

    // MARK: - Watched import

    /// Imports the user's Simkl watched history into the local catalog, marking
    /// matching movies and episodes as watched. Writes through `context` (the
    /// catalog container's context the UI binds to); the iCloud reconciler then
    /// mirrors the change to the user's other devices. No-ops when not connected
    /// or an import is already running.
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
            let items = try await client.watchedItems(accessToken: accessToken)
            lastImport = SimklWatchedImporter.apply(items: items, in: context)
        } catch {
            lastImport = .failure
        }
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
                applyTokens(response.tokens)
                return response.tokens.accessToken
            } catch {
                // Refresh token is dead — drop the session so the UI prompts a
                // reconnect rather than retrying forever.
                await disconnect()
                return nil
            }
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func applyTokens(_ newTokens: SimklTokens) {
        tokens = newTokens
        SimklTokenStore.save(newTokens)
    }
}
