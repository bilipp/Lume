//
//  EPGGridScroller+Preview.swift
//  Lume
//
//  Wires the tvOS Guide's now-playing hero (`EPGPreviewPane`) into the
//  scroller: the Guide opens on its first channel, focus has to rest on
//  another channel before the preview switches to it, and the last channel
//  keeps playing while focus is on the rail or the tab bar.
//

#if os(tvOS)
    import SwiftData
    import SwiftUI
    import UIKit

    extension EPGGridScroller {
        /// The band above the time ruler. Never focusable and outside the
        /// strip's own focus section (only the scroller's outer one spans it),
        /// so Up from the top row still reaches the tab bar.
        var previewBand: some View {
            EPGPreviewBand(
                target: previewTarget,
                settledRow: previewRow,
                dataVersion: dataVersion,
                isFrozen: isPreviewFrozen,
                isFailed: previewTarget.map { previewFailedStreamIDs.contains($0.streamID) } ?? false,
                controller: preview.controller,
                hero: preview.hero,
                playlistID: preview.playlistID,
                onFailure: { [streamID = previewTarget?.streamID] in markPreviewFailed(streamID) }
            )
            .equatable()
            .task(id: PreviewSettleKey(streamID: previewFocusedStreamID, isFrozen: isPreviewFrozen)) {
                await settlePreview()
            }
            .onChange(of: HeroFocusKey(streamID: previewFocusedStreamID, dataVersion: dataVersion), initial: true) {
                publishFocusedRow()
            }
        }

        /// Full screen adopted the preview's running stream: the tile stays
        /// mounted on its channel, whatever focus does underneath the cover.
        private var isPreviewFrozen: Bool {
            guard let controller = preview.controller else { return false }
            return controller.isSuspended && controller.handle.owner == .fullScreen
        }

        /// `nil` while real focus is outside the grid.
        private var previewFocusedStreamID: String? {
            virtualFocusRow?.id
        }

        private var previewRow: EPGChannelRow? {
            guard let target = previewTarget else { return nil }
            if rows.indices.contains(target.rowIndex), rows[target.rowIndex].id == target.streamID {
                return rows[target.rowIndex]
            }
            return rows.first { $0.id == target.streamID }
        }

        private func settlePreview() async {
            // Settles whether or not the preview may play: the hero describes
            // the settled channel and shows its logo when the video can't run.
            guard !isPreviewFrozen else { return }
            let streamID: String
            switch GuidePreviewPolicy.step(
                focused: previewFocusedStreamID,
                current: previewTarget?.streamID,
                first: rows.first?.id
            ) {
            case .keep:
                return
            case let .start(id):
                streamID = id
            case let .settle(id):
                try? await Task.sleep(for: GuidePreviewPolicy.settleDuration)
                guard !Task.isCancelled else { return }
                streamID = id
            }
            guard let rowIndex = rows.firstIndex(where: { $0.id == streamID }) else { return }
            let row = rows[rowIndex]
            previewTarget = EPGPreviewTarget(row: row, rowIndex: rowIndex, media: preview.media(row.stream))
            preview.hero?.settleGlow(onLogo: row.logoURL)
        }

        /// Hands the hero's info block the focused row on every row change,
        /// through the hero model so the scroller never reads it back.
        private func publishFocusedRow() {
            guard let hero = preview.hero else { return }
            // A focus move runs in the focus engine's animated context; the
            // info swaps rather than crossfading on every press.
            withTransaction(Transaction(animation: nil)) {
                hero.focusedRow = virtualFocusRow
            }
        }

        private func markPreviewFailed(_ streamID: String?) {
            guard let streamID else { return }
            Task { @MainActor in
                previewFailedStreamIDs.insert(streamID)
            }
        }
    }

    private struct PreviewSettleKey: Equatable {
        let streamID: String?
        let isFrozen: Bool
    }

    private struct HeroFocusKey: Equatable {
        let streamID: String?
        let dataVersion: Int
    }

    /// Decides whether the band's tile may play at all. Owns the reads that change on
    /// their own — Lume Pro and the accessibility autoplay setting — so they
    /// never re-render the scroller.
    private struct EPGPreviewBand: View, Equatable {
        let target: EPGPreviewTarget?
        /// Compared through `target` and `dataVersion` instead: a channel's
        /// row only changes with the data.
        let settledRow: EPGChannelRow?
        let dataVersion: Int
        let isFrozen: Bool
        let isFailed: Bool
        let controller: GuidePreviewController?
        let hero: GuideHeroModel?
        let playlistID: UUID?
        let onFailure: () -> Void

        @State private var premium = PremiumManager.shared
        @State private var autoplayAllowed = UIAccessibility.isVideoAutoplayEnabled
        /// Read here, never by the scroller, so changing it re-renders only
        /// the band; the grid below takes whatever height the band leaves.
        @AppStorage(PlayerSettings.tvGuidePreviewModeKey)
        private var modeRaw = PlayerSettings.tvGuidePreviewModeDefault.rawValue

        private var mode: GuidePreviewMode {
            GuidePreviewMode(storedValue: modeRaw)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.target == rhs.target
                && lhs.dataVersion == rhs.dataVersion
                && lhs.isFrozen == rhs.isFrozen
                && lhs.isFailed == rhs.isFailed
                && lhs.controller === rhs.controller
                && lhs.hero === rhs.hero
                && lhs.playlistID == rhs.playlistID
        }

        static func isAvailable(mode: GuidePreviewMode, isPremium: Bool, autoplayAllowed: Bool) -> Bool {
            mode.playsVideo && isPremium && autoplayAllowed
        }

        var body: some View {
            Group {
                // Both hero branches keep the hero's full height, so the grid
                // never moves when the preview becomes available or stops
                // being so. Off leaves a zero-height host, never an empty
                // view, so the settle task above keeps running.
                if !mode.showsHero {
                    Color.clear.frame(height: 0)
                } else if Self.isAvailable(mode: mode, isPremium: premium.isPremium, autoplayAllowed: autoplayAllowed) {
                    EPGPreviewBandContent(
                        target: target,
                        settledRow: settledRow,
                        isFrozen: isFrozen,
                        isFailed: isFailed,
                        controller: controller,
                        hero: hero,
                        playlistID: playlistID,
                        onFailure: onFailure
                    )
                } else {
                    EPGPreviewPane(
                        target: target,
                        settledRow: settledRow,
                        hero: hero,
                        isAllowed: false,
                        restartToken: 0,
                        handle: nil,
                        onFailure: onFailure
                    )
                    .equatable()
                }
            }
            .environment(\.epgHeroLayout, EPGHeroLayout(mode))
            .allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.videoAutoplayStatusDidChangeNotification)) { _ in
                autoplayAllowed = UIAccessibility.isVideoAutoplayEnabled
            }
        }
    }

    /// Whether the band's tile may play. Owns the playlist's sync reads and the
    /// controller's suspension, so they re-render only this view.
    private struct EPGPreviewBandContent: View {
        let target: EPGPreviewTarget?
        let settledRow: EPGChannelRow?
        let isFrozen: Bool
        let isFailed: Bool
        let controller: GuidePreviewController?
        let hero: GuideHeroModel?
        let onFailure: () -> Void

        @State private var epgSync = EPGSyncService.shared
        @Query private var playlists: [Playlist]
        @Query private var guideSources: [EPGSource]

        init(
            target: EPGPreviewTarget?,
            settledRow: EPGChannelRow?,
            isFrozen: Bool,
            isFailed: Bool,
            controller: GuidePreviewController?,
            hero: GuideHeroModel?,
            playlistID: UUID?,
            onFailure: @escaping () -> Void
        ) {
            self.target = target
            self.settledRow = settledRow
            self.isFrozen = isFrozen
            self.isFailed = isFailed
            self.controller = controller
            self.hero = hero
            self.onFailure = onFailure
            if let playlistID {
                _playlists = Query(filter: #Predicate<Playlist> { $0.id == playlistID })
                _guideSources = Query(filter: #Predicate<EPGSource> { $0.playlistID == playlistID })
            } else {
                _playlists = Query(filter: #Predicate<Playlist> { _ in false })
                _guideSources = Query(filter: #Predicate<EPGSource> { _ in false })
            }
        }

        private var isSyncing: Bool {
            if playlists.contains(where: { $0.syncStatus == .syncing }) { return true }
            return epgSync.isSyncing
                && guideSources.contains { $0.syncStatus == .syncing }
        }

        private var isAllowed: Bool {
            isFrozen || GuidePreviewPolicy.shouldPreview(
                suspended: controller?.isSuspended ?? false,
                syncing: isSyncing,
                failed: isFailed
            )
        }

        var body: some View {
            EPGPreviewPane(
                target: target,
                settledRow: settledRow,
                hero: hero,
                isAllowed: isAllowed,
                isFailed: isFailed,
                restartToken: controller?.restartToken ?? 0,
                handle: controller?.handle,
                onFailure: onFailure
            )
            .equatable()
        }
    }
#endif
