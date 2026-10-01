//
//  EPGGridScroller+Preview.swift
//  Lume
//
//  Wires the tvOS Guide's live preview band (`EPGPreviewPane`) into the
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
                cells: previewCells,
                dataVersion: dataVersion,
                isFrozen: isPreviewFrozen,
                isFailed: previewTarget.map { previewFailedStreamIDs.contains($0.streamID) } ?? false,
                controller: preview.controller,
                playlistID: preview.playlistID,
                onFailure: { [streamID = previewTarget?.streamID] in markPreviewFailed(streamID) }
            )
            .equatable()
            .task(id: PreviewSettleKey(streamID: previewFocusedStreamID, isFrozen: isPreviewFrozen)) {
                await settlePreview()
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
            guard let focus = virtualFocus, rows.indices.contains(focus.rowIndex) else { return nil }
            return rows[focus.rowIndex].id
        }

        private var previewCells: [EPGProgramCell] {
            guard let target = previewTarget else { return [] }
            if rows.indices.contains(target.rowIndex), rows[target.rowIndex].id == target.streamID {
                return rows[target.rowIndex].cells
            }
            return rows.first { $0.id == target.streamID }?.cells ?? []
        }

        private func settlePreview() async {
            guard !isPreviewFrozen else { return }
            guard EPGPreviewBand.isAvailable(
                isPremium: PremiumManager.shared.isPremium,
                autoplayAllowed: UIAccessibility.isVideoAutoplayEnabled
            ) else {
                if previewTarget != nil { previewTarget = nil }
                return
            }
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

    /// Decides whether the band shows at all. Owns the reads that change on
    /// their own — Lume Pro and the accessibility autoplay setting — so they
    /// never re-render the scroller.
    private struct EPGPreviewBand: View, Equatable {
        let target: EPGPreviewTarget?
        /// Compared through `target` and `dataVersion` instead: the cells of a
        /// channel only change with the data.
        let cells: [EPGProgramCell]
        let dataVersion: Int
        let isFrozen: Bool
        let isFailed: Bool
        let controller: GuidePreviewController?
        let playlistID: UUID?
        let onFailure: () -> Void

        @State private var premium = PremiumManager.shared
        @State private var autoplayAllowed = UIAccessibility.isVideoAutoplayEnabled

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.target == rhs.target
                && lhs.dataVersion == rhs.dataVersion
                && lhs.isFrozen == rhs.isFrozen
                && lhs.isFailed == rhs.isFailed
                && lhs.controller === rhs.controller
                && lhs.playlistID == rhs.playlistID
        }

        static func isAvailable(isPremium: Bool, autoplayAllowed: Bool) -> Bool {
            PlayerSettings.tvGuidePreviewEnabled && isPremium && autoplayAllowed
        }

        var body: some View {
            Group {
                // Fixed per visit, so the grid never changes height while browsing.
                if Self.isAvailable(isPremium: premium.isPremium, autoplayAllowed: autoplayAllowed) {
                    EPGPreviewBandContent(
                        target: target,
                        cells: cells,
                        isFrozen: isFrozen,
                        isFailed: isFailed,
                        controller: controller,
                        playlistID: playlistID,
                        onFailure: onFailure
                    )
                } else {
                    // Zero height rather than `EmptyView`: the scroller's settle
                    // `.task` hangs off this view and never runs on an empty one.
                    Color.clear.frame(height: 0)
                }
            }
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
        let cells: [EPGProgramCell]
        let isFrozen: Bool
        let isFailed: Bool
        let controller: GuidePreviewController?
        let onFailure: () -> Void

        @State private var epgSync = EPGSyncService.shared
        @Query private var playlists: [Playlist]
        @Query private var guideSources: [EPGSource]

        init(
            target: EPGPreviewTarget?,
            cells: [EPGProgramCell],
            isFrozen: Bool,
            isFailed: Bool,
            controller: GuidePreviewController?,
            playlistID: UUID?,
            onFailure: @escaping () -> Void
        ) {
            self.target = target
            self.cells = cells
            self.isFrozen = isFrozen
            self.isFailed = isFailed
            self.controller = controller
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
                cells: cells,
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
