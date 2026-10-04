//
//  TVRecordingsView.swift
//  Lume
//
//  The recordings library on tvOS, shown beside the Live TV category rail
//  when its Recordings entry is picked: one full-width band of cards per
//  status, play on select, stop / cancel / delete from the card's menu.
//

#if os(tvOS)
    import LumeRecorderKit
    import SwiftUI

    struct TVRecordingsView: View {
        @State private var model = RecordingsLibraryModel()

        private var store: RecordingServerStore {
            model.store
        }

        var body: some View {
            let groups = RecordingsLibrary.groups(model.visibleRecordings)
            Group {
                if groups.isEmpty {
                    RecordingsLibraryEmptyState(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    library(groups)
                }
            }
            .focusSection()
            .recordingsLibraryActions(model)
            .fullScreenCover(item: $model.playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
        }

        // MARK: - Library

        private func library(_ groups: [RecordingsLibraryGroup]) -> some View {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    if case let .unreachable(error) = store.reachability {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, TVRecordingsMetrics.bandInset)
                    }
                    ForEach(groups) { group in
                        TVRecordingsBand(group: group) { recording in
                            card(for: recording)
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            // tvOS scroll views draw outside their bounds; the bands scroll
            // inside the pane instead of under the tab bar.
            .clipped()
        }

        private func card(for recording: Recording) -> some View {
            TVRecordingCard(recording: recording, isLoading: model.loadingID == recording.id) {
                if recording.isPlayable {
                    model.play(recording)
                } else {
                    model.pendingAction = RecordingLibraryAction.actions(for: recording).first
                }
            }
            .contextMenu {
                if recording.isPlayable {
                    Button {
                        model.play(recording)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                ForEach(RecordingLibraryAction.actions(for: recording)) { action in
                    Button(role: action.isDelete ? .destructive : nil) {
                        model.pendingAction = action
                    } label: {
                        Label(action.menuLabel, systemImage: action.systemImage)
                    }
                }
            }
        }
    }

    private enum TVRecordingsMetrics {
        static let cardWidth = TVDetailMetrics.episodeCardWidth
        static let artHeight = TVDetailMetrics.episodeStillHeight
        /// Room for the focused card's lift inside the band's clip.
        static let bandInset: CGFloat = 24
    }

    // MARK: - Band

    /// One status section: a header over a horizontal row of cards. The band
    /// spans the pane, so Up / Down from any card lands in the next band.
    private struct TVRecordingsBand<Card: View>: View {
        let group: RecordingsLibraryGroup
        @ViewBuilder var card: (Recording) -> Card

        @FocusState private var focusedID: UUID?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(group.section.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, TVRecordingsMetrics.bandInset)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVDetailMetrics.railSpacing) {
                        ForEach(group.recordings) { recording in
                            card(recording)
                                .focused($focusedID, equals: recording.id)
                        }
                    }
                    .padding(TVRecordingsMetrics.bandInset)
                }
                // Clipped so scrolled-off cards never draw over the rail.
                .clipped()
                // Entry from the band above or below lands on the first card,
                // not the one nearest the band's center.
                .defaultFocus($focusedID, group.recordings.first?.id, priority: .userInitiated)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }

    // MARK: - Card

    private struct TVRecordingCard: View {
        let recording: Recording
        let isLoading: Bool
        let onSelect: () -> Void

        private var artShape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
        }

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 14) {
                    art
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recording.title)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let channel = recording.channelName, !channel.isEmpty {
                            Text(channel)
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        Text(recording.timeRangeText)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                        if let line = recording.failureText ?? recording.detailText {
                            Text(line)
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.55))
                                .monospacedDigit()
                                .lineLimit(2)
                        }
                    }
                    .frame(width: TVRecordingsMetrics.cardWidth, alignment: .leading)
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .accessibilityElement(children: .combine)
        }

        private var art: some View {
            ZStack {
                artShape.fill(.white.opacity(0.08))

                CachedAsyncImage(url: recording.channelLogoURL, maxPixelSize: 320) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "tv")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .frame(width: 200, height: 110)

                statusBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(14)
                } else if recording.isPlayable {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(14)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: TVRecordingsMetrics.cardWidth, height: TVRecordingsMetrics.artHeight)
            .clipShape(artShape)
            .overlay { TVRecordingCardFocusRing(shape: artShape) }
        }

        private var statusBadge: some View {
            Label(recording.statusText, systemImage: recording.statusSystemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(recording.statusColor.opacity(0.85)))
        }
    }

    /// The art has no picture of its own, so the lift alone barely reads on
    /// the dark Live TV background; a ring marks the focused card.
    private struct TVRecordingCardFocusRing: View {
        let shape: RoundedRectangle
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            shape
                .strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
#endif
