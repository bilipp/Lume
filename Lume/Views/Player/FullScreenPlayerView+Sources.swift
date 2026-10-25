//
//  FullScreenPlayerView+Sources.swift
//  Lume
//
//  The player host's half of choosing a Jellyfin/Emby version: what it shows
//  while a version is looked up or chosen, what an engine that can't start
//  one falls back to, and the mid-stream picker the Sources control opens.
//  The state lives in `PlayerSourceSession`. Also the Stalker `create_link`
//  resolution, the other stream that has to be resolved before it can play.
//

import OSLog
import SwiftData
import SwiftUI

extension FullScreenPlayerView {
    /// Resolves the active Stalker placeholder into a playable URL. A no-op for
    /// directly playable streams. Re-runs whenever the active stream changes
    /// (open, channel surf, next episode), so each switch resolves a fresh,
    /// short-lived URL.
    func resolveActiveMedia() async {
        if await resolveSources() { return }
        guard StalkerLink.isPlaceholder(activeMedia.url), !keepsAdoptedResolution, !castKeepsResolution else { return }
        resolvedMedia = nil
        resolveError = nil
        do {
            resolvedMedia = try await StalkerStreamResolver.resolve(activeMedia, container: modelContext.container)
        } catch {
            resolveError = error.localizedDescription
            let detail = (error as? StalkerError)?.logDescription ?? LogRedaction.describe(error)
            Logger.player.error("Stalker stream resolution failed: \(detail, privacy: .public)")
        }
    }

    func retryResolve() {
        engineAttempt = 0
        Task { await resolveActiveMedia() }
    }

    /// Whether an engine that can't start the stream reports it to the host
    /// rather than showing its own error: another engine is left to try, or
    /// another version of the title.
    var reportsStartupFailure: Bool {
        hasFallbackEngine || sourceSession.canRecoverFromFailure
    }

    /// Looks the active stream's versions up. `false` when it isn't a
    /// Jellyfin/Emby title, which leaves the stream to the Stalker path.
    func resolveSources(refresh: Bool = false) async -> Bool {
        await sourceSession.begin(for: activeMedia, context: modelContext, refresh: refresh)
    }

    /// Every engine failed to start the playing version: ask for another.
    func recoverWithAnotherSource() {
        if sourceSession.recoverFromFailure() {
            engineAttempt = 0
        }
    }

    /// What stands in for the engine while the session has no version ready.
    @ViewBuilder
    var sourcePhaseView: some View {
        let failure: String? = if case let .failed(message) = sourceSession.phase { message } else { nil }
        MediaSourcePickerView(
            title: activeMedia.title,
            subtitle: activeMedia.subtitle,
            options: sourceSession.options,
            isLoading: sourceSession.phase == .loading || sourceSession.phase == .idle,
            currentId: nil,
            failedIds: sourceSession.failedIds,
            rememberedId: sourceSession.rememberedOptionId,
            failureMessage: failure,
            onRetry: { Task { _ = await resolveSources(refresh: true) } },
            onPick: { option in
                sourceSession.choose(option)
                engineAttempt = 0
            },
            onClose: closePlayer
        )
    }

    /// Plays `option` from where the viewer is, on the primary engine.
    func switchSource(to option: MediaSourceOption) {
        guard option.id != sourceSession.currentOptionId else {
            sourceSession.isPresentingSwitcher = false
            return
        }
        sourceSession.choose(option, startTime: activeMedia.isLive ? nil : clock.current)
        engineAttempt = 0
    }
}

/// Hands the session to the engine overlays' Sources control and presents
/// the mid-stream picker it opens.
struct PlayerSourceSwitcherHost: ViewModifier {
    @Bindable var session: PlayerSourceSession
    let media: PlayableMedia
    let onPick: (MediaSourceOption) -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.playerSourceSession, session)
        #if os(tvOS)
            .fullScreenCover(isPresented: $session.isPresentingSwitcher) { picker }
        #else
            .sheet(isPresented: $session.isPresentingSwitcher) {
                picker
                #if os(macOS)
                // A frameless macOS sheet collapses its scroll view to zero.
                .frame(minWidth: 520, idealWidth: 640, minHeight: 460, idealHeight: 620)
                #endif
            }
        #endif
    }

    private var picker: some View {
        MediaSourcePickerView(
            title: media.title,
            subtitle: media.subtitle,
            options: session.options,
            isLoading: false,
            currentId: session.currentOptionId,
            failedIds: session.failedIds,
            onPick: onPick,
            onClose: { session.isPresentingSwitcher = false }
        )
    }
}
