//
//  ChannelsListView.swift
//  Lume
//
//  The iOS / macOS Live TV channel list: a paged, lazily-mounted list of the
//  channels in the selected section, each card carrying the now/next EPG the
//  list resolves for its visible window (see `ChannelEPGSnapshot`). Split out of
//  `LiveTVView` for the same reason `LiveTVTVComponents` holds the tvOS list —
//  to keep that file focused on cross-platform composition, and inside the
//  project's file-length cap.
//

import SwiftData
import SwiftUI

struct ChannelsList: View {
    let scope: LiveChannelScope
    let playlistPrefix: String
    /// Seeds Multi-View with this channel, gated on Lume Pro by the host.
    let onStartMultiView: (LiveStream) -> Void
    let onPlay: (LiveStream) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Query private var streams: [LiveStream]
    /// Now/next EPG for the visible channels, resolved in one off-main fetch
    /// (see `ChannelEPGSnapshot`) instead of a per-card `@Query`.
    @State private var epgByChannel: [String: ChannelEPG] = [:]
    /// The channels `epgByChannel` was resolved for, when it was last resolved
    /// from scratch, and the channel-set identity it belongs to — so a
    /// pagination step looks up only the page it added. Re-resolving the whole
    /// visible prefix each step made scrolling a large category cost more with
    /// every page: page *n* re-fetched the `n × 50` channels above it.
    @State private var resolvedChannelIds: Set<String> = []
    @State private var resolvedAt = Date.distantPast
    @State private var resolvedGeneration = ""
    /// Observed so the EPG lookup refreshes when a guide import finishes.
    @State private var epgSync = EPGSyncService.shared
    /// How many channels are currently rendered. Grows by a page as the list
    /// nears its end so a large category loads lazily instead of all at once.
    @State private var visibleCount = LiveChannelQuery.pageSize
    /// Drives the "Clear Recently Watched" confirmation alert.
    @State private var confirmingClear = false

    init(
        scope: LiveChannelScope,
        playlistPrefix: String,
        sort: ContentSortOption,
        onStartMultiView: @escaping (LiveStream) -> Void,
        onPlay: @escaping (LiveStream) -> Void
    ) {
        self.scope = scope
        self.playlistPrefix = playlistPrefix
        self.onStartMultiView = onStartMultiView
        self.onPlay = onPlay
        _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))
    }

    private var scopedStreams: [LiveStream] {
        LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix, restriction: restriction)
    }

    /// Clears a channel's watch timestamp so it drops out of the Recently
    /// Watched list. The @Query-backed list updates once the change is saved.
    private func removeFromRecentlyWatched(_ stream: LiveStream) {
        stream.lastWatchedDate = nil
        try? modelContext.save()
    }

    /// Empties the whole Recently Watched list for the active playlist. The
    /// section drops away on its own once the last timestamp clears (its parent
    /// gates it on `hasRecents`).
    private func clearRecentlyWatched() {
        let container = modelContext.container
        Task { await StorageManager.clearRecentlyWatchedChannels(playlistPrefix: playlistPrefix, container: container) }
    }

    /// A trailing "Clear" button shown above the Recently Watched list. Stays
    /// out of the scroll view so it's always reachable no matter how far the
    /// list is scrolled.
    private var clearHeader: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    var body: some View {
        let channels = scopedStreams
        let visible = Array(channels.prefix(visibleCount))
        // What makes the resolved EPG stale wholesale rather than merely
        // incomplete: the channel set changing, or a guide import settling.
        let generation = "\(channels.count)-\(epgSync.isSyncing)"
        VStack(spacing: 0) {
            if scope == .recentlyWatched, !channels.isEmpty {
                clearHeader
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if channels.isEmpty {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("This category has no channels")
                        )
                    } else {
                        ForEach(visible) { stream in
                            Button {
                                onPlay(stream)
                            } label: {
                                LiveStreamCardView(stream: stream, epg: epgByChannel[stream.epgChannelId ?? ""])
                                    .padding(.horizontal)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .liveChannelMenu(
                                isFavorite: stream.isFavorite,
                                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) },
                                onStartMultiView: { onStartMultiView(stream) },
                                onRemoveFromRecents: scope == .recentlyWatched ? { removeFromRecentlyWatched(stream) } : nil
                            )
                            .onAppear {
                                if stream.id == visible.last?.id, visibleCount < channels.count {
                                    visibleCount = min(visibleCount + LiveChannelQuery.pageSize, channels.count)
                                }
                            }

                            Divider()
                                .padding(.leading, 88)
                        }
                    }
                }
            }
            .browseActivity()
            // Reload when the visible window or channel set changes, or a guide
            // import settles — EPG is resolved only for the channels on screen.
            .task(id: "\(generation)-\(visible.count)") {
                await loadEPG(for: visible, generation: generation)
            }
        }
        .alert("Clear Recently Watched", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { clearRecentlyWatched() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the list of channels you've recently watched. Your favorites and the channels themselves aren't affected.")
        }
    }

    private func loadEPG(for channels: [LiveStream], generation: String) async {
        let channelIds = Array(Set(channels.compactMap(\.epgChannelId).filter { !$0.isEmpty }))
        guard !channelIds.isEmpty else {
            epgByChannel = [:]
            resolvedChannelIds = []
            resolvedGeneration = generation
            return
        }
        let now = Date()
        // Extend the snapshot with the channels that just scrolled into view.
        // Resolving from scratch is kept for a stale generation and for pairs
        // old enough that a programme could have ended under them, so no card
        // is ever more than `snapshotLifetime` behind the guide.
        let extending = generation == resolvedGeneration
            && now.timeIntervalSince(resolvedAt) < ChannelEPGLoader.snapshotLifetime
        let pending = extending ? channelIds.filter { !resolvedChannelIds.contains($0) } : channelIds
        guard !pending.isEmpty else { return }

        let container = modelContext.container
        let resolved = await Task.detached(priority: .userInitiated) {
            ChannelEPGLoader.load(container: container, channelIds: pending, now: now)
        }.value
        if extending {
            // `pending`, not `resolved`: a channel the guide has nothing for
            // must still count as looked up, or every page would ask again.
            epgByChannel.merge(resolved) { _, new in new }
            resolvedChannelIds.formUnion(pending)
        } else {
            epgByChannel = resolved
            resolvedChannelIds = Set(pending)
            resolvedAt = now
        }
        resolvedGeneration = generation
    }
}
