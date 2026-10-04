//
//  RecordingsView.swift
//  Lume
//
//  The recordings library on iOS, macOS and visionOS: the paired server's
//  recordings by status, with stop, cancel and delete, and playback of
//  anything that has captured video. Opened from the Live TV toolbar and
//  from Settings › Live TV.
//

import LumeRecorderKit
import SwiftUI

extension View {
    /// Adds the Recordings button to the Live TV toolbar once a recording
    /// server is paired. Without Lume Pro it carries the crown and opens the
    /// paywall. tvOS reaches the library from the Live TV rail and its
    /// Settings pane instead.
    @ViewBuilder
    func recordingsLibraryToolbar() -> some View {
        #if os(tvOS)
            self
        #else
            modifier(RecordingsLibraryToolbarModifier())
        #endif
    }
}

#if !os(tvOS)

    extension View {
        /// The recordings library as a sheet, the way every iOS / macOS /
        /// visionOS entry point presents it (macOS sizes the sheet itself).
        func recordingsLibrarySheet(isPresented: Binding<Bool>) -> some View {
            sheet(isPresented: isPresented) {
                NavigationStack {
                    RecordingsView()
                }
                .recordingsSheetFrame()
            }
        }
    }

    private struct RecordingsLibraryToolbarModifier: ViewModifier {
        @State private var store = RecordingServerStore.shared
        @State private var showingRecordings = false
        @State private var showingPaywall = false

        func body(content: Content) -> some View {
            content
                .toolbar {
                    if store.isPaired {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                if store.isUnlocked {
                                    showingRecordings = true
                                } else {
                                    showingPaywall = true
                                }
                            } label: {
                                Label("Recordings", systemImage: store.isUnlocked ? "recordingtape" : "crown")
                            }
                        }
                    }
                }
                .recordingsLibrarySheet(isPresented: $showingRecordings)
                .paywall(isPresented: $showingPaywall, highlight: .recordingServer)
        }
    }

    struct RecordingsView: View {
        @Environment(\.dismiss) private var dismiss

        @State private var model = RecordingsLibraryModel()

        private var store: RecordingServerStore {
            model.store
        }

        var body: some View {
            let groups = RecordingsLibrary.groups(model.visibleRecordings)
            List {
                if case let .unreachable(error) = store.reachability, !groups.isEmpty {
                    Section {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section(group.section.title) {
                        ForEach(group.recordings) { recording in
                            row(for: recording)
                        }
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    RecordingsLibraryEmptyState(store: store)
                }
            }
            .refreshable { await store.refresh() }
            .platformNavigationTitle("Recordings")
            .toolbar { toolbarContent }
            .recordingsLibraryActions(model, confirmsOnRows: true)
            .recordingPlayer(item: $model.playingMedia)
        }

        // MARK: - Rows

        @ViewBuilder
        private func row(for recording: Recording) -> some View {
            let content = RecordingRow(recording: recording, isLoading: model.loadingID == recording.id)
            Group {
                if recording.isPlayable {
                    Button {
                        model.play(recording)
                    } label: {
                        content
                    }
                    .buttonStyle(.plain)
                } else {
                    content
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                ForEach(RecordingLibraryAction.actions(for: recording)) { action in
                    Button {
                        model.pendingAction = action
                    } label: {
                        Label(action.menuLabel, systemImage: action.systemImage)
                    }
                    .tint(action.tint)
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
            .recordingActionConfirmation(model, for: recording)
        }

        @ToolbarContentBuilder
        private var toolbarContent: some ToolbarContent {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }
            #endif
        }
    }

    // MARK: - Row

    private struct RecordingRow: View {
        let recording: Recording
        let isLoading: Bool

        var body: some View {
            HStack(spacing: 14) {
                logo

                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let channel = recording.channelName, !channel.isEmpty {
                        Text(channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(recording.timeRangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Label(recording.statusText, systemImage: recording.statusSystemImage)
                            .foregroundStyle(recording.statusColor)
                        if let detail = recording.detailText {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    if let failure = recording.failureText {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView()
                } else if recording.isPlayable {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }

        private var logo: some View {
            CachedAsyncImage(url: recording.channelLogoURL, maxPixelSize: 88) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit()
                default:
                    Image(systemName: "tv")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Presentation

    private extension View {
        /// The player for a recording: macOS's single player window, a full
        /// screen cover everywhere else.
        func recordingPlayer(item: Binding<PlayableMedia?>) -> some View {
            modifier(RecordingPlayerPresentation(media: item))
        }

        @ViewBuilder
        func recordingsSheetFrame() -> some View {
            #if os(macOS)
                frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
            #else
                self
            #endif
        }
    }

    private struct RecordingPlayerPresentation: ViewModifier {
        @Binding var media: PlayableMedia?
        #if os(macOS)
            @Environment(\.openWindow) private var openWindow
        #endif

        func body(content: Content) -> some View {
            #if os(macOS)
                content
                    .onChange(of: media) { _, newValue in
                        guard let newValue else { return }
                        MacPlayerWindowRouter.shared.play(newValue, using: openWindow)
                        media = nil
                    }
            #else
                content
                    .fullScreenCover(item: $media) { media in
                        FullScreenPlayerView(media: media)
                    }
            #endif
        }
    }

#endif
