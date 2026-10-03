//
//  EPGPreviewPane.swift
//  Lume
//
//  The tvOS Guide's now-playing hero: what the focused channel is airing on
//  the left, the settled channel's muted picture on the right. It sits above the time ruler,
//  outside the focus strip, and is never a focus target.
//

#if os(tvOS)
    import SwiftUI

    extension EPGMetrics {
        var previewVideoCornerRadius: CGFloat {
            28
        }

        var previewSpacing: CGFloat {
            48
        }
    }

    /// The hero's size for the chosen `GuidePreviewMode`. Small frees exactly
    /// two guide rows (2 × 80 pt) and compacts the info beside the picture.
    struct EPGHeroLayout: Equatable {
        let height: CGFloat
        let isCompact: Bool

        init(_ mode: GuidePreviewMode) {
            switch mode {
            case .regular, .infoOnly:
                height = 360
                isCompact = false
            case .small:
                height = 200
                isCompact = true
            case .off:
                height = 0
                isCompact = false
            }
        }

        /// 16:9 at the hero's height.
        var videoWidth: CGFloat {
            (height * 16 / 9).rounded()
        }

        /// The gap between the hero and the time ruler beneath it.
        var bottomPadding: CGFloat {
            height > 0 ? 36 : 0
        }
    }

    extension EnvironmentValues {
        /// Set by the Guide's preview band for the hero inside it.
        @Entry var epgHeroLayout = EPGHeroLayout(.regular)
    }

    /// The channel the preview has settled on, snapshotted so comparing panes
    /// never touches the SwiftData model.
    struct EPGPreviewTarget: Equatable {
        let streamID: String
        /// Where the row sat when the preview settled; re-checked against
        /// `streamID` before use.
        let rowIndex: Int
        let name: String
        let logoURL: URL?
        /// `nil` until a stream to open is known.
        let media: PlayableMedia?
    }

    extension EPGPreviewTarget {
        init(row: EPGChannelRow, rowIndex: Int, media: PlayableMedia?) {
            self.init(
                streamID: row.id,
                rowIndex: rowIndex,
                name: row.name,
                logoURL: row.logoURL,
                media: media
            )
        }
    }

    struct EPGPreviewPane: View, Equatable {
        let target: EPGPreviewTarget?
        /// The settled channel's row, described while focus is outside the
        /// guide.
        let settledRow: EPGChannelRow?
        /// Read only by the info block, which follows the focused row, and the
        /// placeholder card's tint.
        let hero: GuideHeroModel?
        let isAllowed: Bool
        /// The channel already failed this Guide visit and is not retried.
        let isFailed: Bool
        /// Bumped to reopen a fresh stream on the same channel.
        let restartToken: Int
        let handle: PreviewPlayerHandle?
        let onFailure: () -> Void

        private let metrics = EPGMetrics.current
        @Environment(\.epgHeroLayout) private var layout
        /// Per pane, so a stale pane's late `onDisappear` can't release the
        /// hold of the pane that replaced it.
        @State private var holdOwner = "guide-preview-\(UUID().uuidString)"

        init(
            target: EPGPreviewTarget?,
            settledRow: EPGChannelRow?,
            hero: GuideHeroModel?,
            isAllowed: Bool,
            isFailed: Bool = false,
            restartToken: Int,
            handle: PreviewPlayerHandle?,
            onFailure: @escaping () -> Void
        ) {
            self.target = target
            self.settledRow = settledRow
            self.hero = hero
            self.isAllowed = isAllowed
            self.isFailed = isFailed
            self.restartToken = restartToken
            self.handle = handle
            self.onFailure = onFailure
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.target == rhs.target
                && lhs.settledRow?.cells == rhs.settledRow?.cells
                && lhs.hero === rhs.hero
                && lhs.isAllowed == rhs.isAllowed
                && lhs.isFailed == rhs.isFailed
                && lhs.restartToken == rhs.restartToken
                && lhs.handle === rhs.handle
        }

        var body: some View {
            // The info starts at the band's leading edge, level with the focus
            // strip: `EPGFocusStrip` reads anything left of the strip as the rail.
            HStack(alignment: .bottom, spacing: metrics.previewSpacing) {
                EPGHeroInfo(hero: hero, settled: settledRow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                EPGHeroVideoFigure(
                    target: target,
                    isAllowed: isAllowed,
                    isFailed: isFailed,
                    restartToken: restartToken,
                    handle: handle,
                    hero: hero,
                    onFailure: onFailure
                )
            }
            .frame(height: layout.height)
            .padding(.bottom, layout.bottomPadding)
            .focusable(false)
            .accessibilityHidden(true)
            .onChange(of: holdsPlayback, initial: true) { _, holds in
                PlaybackSurfaceHold.set(holds, owner: holdOwner)
            }
            .onDisappear { PlaybackSurfaceHold.set(false, owner: holdOwner) }
        }

        /// Released once full screen adopts the stream, so its QoE session
        /// records as any other full-screen session does.
        private var holdsPlayback: Bool {
            target?.media != nil && isAllowed && handle?.owner != .fullScreen
        }
    }

    #Preview("Guide preview band") {
        let now = Date()
        let cells = [
            EPGProgramCell(
                id: "a", title: "Morning Show", detail: "",
                start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-600),
                listingID: "a", isGap: false, width: 300
            ),
            EPGProgramCell(
                id: "b", title: "The Evening News", detail: "",
                start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1800),
                listingID: "b", isGap: false, width: 240
            )
        ]
        let row = EPGChannelRow(
            id: "1", stream: LiveStream(id: "1", streamId: 1, name: "BBC One"), name: "BBC One",
            logoURL: nil, catchupCapable: false, archiveDays: 1, cells: cells
        )
        VStack(alignment: .leading, spacing: 40) {
            EPGPreviewPane(
                target: EPGPreviewTarget(row: row, rowIndex: 0, media: nil),
                settledRow: row,
                hero: nil,
                isAllowed: false,
                restartToken: 0,
                handle: nil,
                onFailure: {}
            )
            EPGPreviewPane(
                target: EPGPreviewTarget(streamID: "2", rowIndex: 1, name: "CNN International", logoURL: nil, media: nil),
                settledRow: nil,
                hero: nil,
                isAllowed: true,
                isFailed: true,
                restartToken: 0,
                handle: nil,
                onFailure: {}
            )
            EPGPreviewPane(target: nil, settledRow: nil, hero: nil, isAllowed: true, restartToken: 0, handle: nil, onFailure: {})
        }
        .padding(60)
    }
#endif
