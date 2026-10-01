//
//  EPGPreviewPane.swift
//  Lume
//
//  The tvOS Guide's live preview band: a muted picture of the settled channel
//  over the channel column, and what it is airing now beside it. It sits
//  above the time ruler, outside the focus strip, and is never a focus target.
//

#if os(tvOS)
    import SwiftUI

    extension EPGMetrics {
        var previewBandHeight: CGFloat {
            200
        }

        /// The video spans the channel column, so nothing in the band sits left
        /// of it — `EPGFocusStrip` would read anything there as the rail.
        var previewVideoWidth: CGFloat {
            channelColumnWidth
        }

        var previewSpacing: CGFloat {
            32
        }

        /// The gap between the band and the time ruler beneath it.
        var previewBandBottomPadding: CGFloat {
            rowSpacing * 2
        }
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
            self.init(streamID: row.id, rowIndex: rowIndex, name: row.name, logoURL: row.logoURL, media: media)
        }
    }

    struct EPGPreviewPane: View, Equatable {
        let target: EPGPreviewTarget?
        /// The focused row's cells; the info line always shows the programme
        /// airing now, whichever cell has focus.
        let cells: [EPGProgramCell]
        let isAllowed: Bool
        /// The channel already failed this Guide visit and is not retried.
        let isFailed: Bool
        /// Bumped to reopen a fresh stream on the same channel.
        let restartToken: Int
        let handle: PreviewPlayerHandle?
        let onFailure: () -> Void

        private let metrics = EPGMetrics.current
        /// Per pane, so a stale pane's late `onDisappear` can't release the
        /// hold of the pane that replaced it.
        @State private var holdOwner = "guide-preview-\(UUID().uuidString)"

        init(
            target: EPGPreviewTarget?,
            cells: [EPGProgramCell],
            isAllowed: Bool,
            isFailed: Bool = false,
            restartToken: Int,
            handle: PreviewPlayerHandle?,
            onFailure: @escaping () -> Void
        ) {
            self.target = target
            self.cells = cells
            self.isAllowed = isAllowed
            self.isFailed = isFailed
            self.restartToken = restartToken
            self.handle = handle
            self.onFailure = onFailure
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.target == rhs.target
                && lhs.cells == rhs.cells
                && lhs.isAllowed == rhs.isAllowed
                && lhs.isFailed == rhs.isFailed
                && lhs.restartToken == rhs.restartToken
                && lhs.handle === rhs.handle
        }

        var body: some View {
            HStack(alignment: .center, spacing: metrics.previewSpacing) {
                video
                    .frame(width: metrics.previewVideoWidth, height: metrics.previewVideoWidth * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.blockCornerRadius, style: .continuous))

                if let target {
                    TimelineView(.everyMinute) { context in
                        EPGPreviewInfo(
                            channelName: target.name,
                            programme: GuidePreviewPolicy.currentProgramme(in: cells, at: context.date),
                            now: context.date
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(height: metrics.previewBandHeight)
            .padding(.bottom, metrics.previewBandBottomPadding)
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

        private var video: some View {
            ZStack {
                Color.black

                if let target {
                    if isFailed {
                        LiveChannelUnavailableBadge(logoURL: target.logoURL, logoSide: 96)
                    } else if isAllowed, let media = target.media {
                        MultiViewTilePlayer(
                            media: media,
                            isMuted: true,
                            role: .guidePreview(handle: handle),
                            onFailure: onFailure
                        )
                        .id("\(target.streamID)-\(restartToken)")
                    } else {
                        LiveChannelLogoPlaceholder(url: target.logoURL, side: 96)
                    }
                }
            }
        }
    }

    private struct EPGPreviewInfo: View {
        let channelName: String
        let programme: EPGProgramCell?
        let now: Date

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let programme {
                    Text(programme.title)
                        .font(.system(size: 34, weight: .semibold))
                        .lineLimit(1)
                    Text(programme.start ..< programme.end, format: .interval.hour().minute())
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    ProgressView(value: programme.progress(at: now))
                        .progressViewStyle(.linear)
                        // `Color.accentColor` is white on tvOS.
                        .tint(.red)
                        .frame(maxWidth: 520)
                }
                Text(channelName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
        VStack(alignment: .leading, spacing: 40) {
            EPGPreviewPane(
                target: EPGPreviewTarget(streamID: "1", rowIndex: 0, name: "BBC One", logoURL: nil, media: nil),
                cells: cells,
                isAllowed: false,
                restartToken: 0,
                handle: nil,
                onFailure: {}
            )
            EPGPreviewPane(
                target: EPGPreviewTarget(streamID: "2", rowIndex: 1, name: "CNN International", logoURL: nil, media: nil),
                cells: [],
                isAllowed: true,
                isFailed: true,
                restartToken: 0,
                handle: nil,
                onFailure: {}
            )
            EPGPreviewPane(target: nil, cells: [], isAllowed: true, restartToken: 0, handle: nil, onFailure: {})
        }
        .padding(60)
    }
#endif
