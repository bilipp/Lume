//
//  StorageManagementView.swift
//  Lume
//
//  Shows how much content is stored (movies, series, episodes, channels) and
//  how much disk the catalog and image cache occupy, with actions to clear the
//  image cache and the cached TMDB/OMDb metadata. iOS/macOS render a grouped
//  list; tvOS renders flat sections that drop into the Settings detail pane.
//

import SwiftData
import SwiftUI

struct StorageManagementView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var stats: StorageStats?
    @State private var isClearing = false
    @State private var confirmImageClear = false
    @State private var confirmMetadataClear = false
    @State private var confirmHistoryClear = false
    @State private var indexing = ContentIndexingService.shared
    #if DEBUG
        @State private var confirmIndexClear = false
    #endif

    private enum ClearAction {
        case imageCache, metadata, watchHistory
        #if DEBUG
            case index
        #endif
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    // MARK: - Shared logic

    private func load() async {
        stats = await StorageManager.gatherStats(in: modelContext)
    }

    private func perform(_ action: ClearAction) async {
        isClearing = true
        switch action {
        case .imageCache:
            await StorageManager.clearImageCache()
        case .metadata:
            await StorageManager.clearMetadataEnrichment(container: modelContext.container)
        case .watchHistory:
            await StorageManager.clearWatchHistory(container: modelContext.container)
        #if DEBUG
            case .index:
                indexing.reset()
                await StorageManager.clearIndex(container: modelContext.container)
                indexing.kick()
        #endif
        }
        await load()
        isClearing = false
    }

    private func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func countText(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }

    // MARK: - iOS / macOS (grouped list)

    #if !os(tvOS)
        private var standardBody: some View {
            List {
                Section {
                    LabeledContent("Movies", value: countText(stats?.movieCount))
                    LabeledContent("Series", value: countText(stats?.seriesCount))
                    LabeledContent("Channels", value: countText(stats?.channelCount))
                } header: {
                    Text("Library")
                }

                Section {
                    LabeledContent("Library Data", value: sizeText(stats?.catalogBytes))
                    LabeledContent("Image Cache", value: sizeText(stats?.imageCacheBytes))
                } header: {
                    Text("Storage Used")
                }

                Section {
                    HStack {
                        Label("Content Indexing", systemImage: "sparkles")
                        Spacer()
                        if indexing.state == .indexing || indexing.state == .preparing {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 2)
                        }
                        Text(indexing.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    #if DEBUG
                        Button(role: .destructive) {
                            confirmIndexClear = true
                        } label: {
                            Label("Clear Index", systemImage: "trash")
                        }
                        .disabled(isClearing)
                    #endif
                } header: {
                    Text("Indexing")
                } footer: {
                    Text("Matches your library against TMDB and builds an on-device index for smarter search. Runs slowly in the background.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmImageClear = true
                    } label: {
                        Label("Clear Image Cache", systemImage: "photo.stack")
                    }
                    Button(role: .destructive) {
                        confirmMetadataClear = true
                    } label: {
                        Label("Clear Metadata Cache", systemImage: "text.below.photo")
                    }
                } footer: {
                    Text("Clearing caches frees up space. Artwork and metadata re-download automatically when needed. Your playlists, downloads, watch history and favorites are not affected.")
                }
                .disabled(isClearing)

                Section {
                    Button(role: .destructive) {
                        confirmHistoryClear = true
                    } label: {
                        Label("Clear Watch History", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(isClearing)
                } header: {
                    Text("Watch History")
                } footer: {
                    Text("Removes watch progress and the watched status of every title, and empties your Continue Watching and Recently Watched lists. Favorites and your watchlist aren't affected.")
                }
            }
            .platformNavigationTitle("Storage & Cache")
            .task { await load() }
            .clearConfirmations(
                confirmImageClear: $confirmImageClear,
                confirmMetadataClear: $confirmMetadataClear,
                onClearImageCache: { Task { await perform(.imageCache) } },
                onClearMetadata: { Task { await perform(.metadata) } }
            )
            .watchHistoryConfirmation(
                isPresented: $confirmHistoryClear,
                onClear: { Task { await perform(.watchHistory) } }
            )
            #if DEBUG
            .alert("Clear Index", isPresented: $confirmIndexClear) {
                    Button("Clear", role: .destructive) { Task { await perform(.index) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The TMDB metadata and on-device embeddings for every title will be wiped, then re-indexed from scratch in the background.")
                }
            #endif
        }
    #endif

    // MARK: - tvOS (flat sections inside the Settings detail pane)

    #if os(tvOS)
        private var tvBody: some View {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Library")
                    TVSettingsValueRow("Movies", value: countText(stats?.movieCount))
                    TVSettingsValueRow("Series", value: countText(stats?.seriesCount))
                    TVSettingsValueRow("Channels", value: countText(stats?.channelCount))
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Storage Used")
                    TVSettingsValueRow("Library Data", value: sizeText(stats?.catalogBytes))
                    TVSettingsValueRow("Image Cache", value: sizeText(stats?.imageCacheBytes))
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Content Indexing")

                    HStack(spacing: 12) {
                        if indexing.state == .indexing || indexing.state == .preparing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(indexing.statusText)
                            .font(.system(size: 24))
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, 4)

                    Text("Matches your library against TMDB and builds an on-device index for smarter search. Runs slowly in the background.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)

                    #if DEBUG
                        tvClearRow(title: "Clear Index", size: nil) {
                            confirmIndexClear = true
                        }
                        .disabled(isClearing)
                    #endif
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Clear")
                    tvClearRow(title: "Clear Image Cache", size: stats?.imageCacheBytes) {
                        confirmImageClear = true
                    }
                    tvClearRow(title: "Clear Metadata Cache", size: nil) {
                        confirmMetadataClear = true
                    }

                    Text("Cached artwork and metadata are re-downloaded automatically when needed. Your playlists, downloads, watch history and favorites are not affected.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
                .disabled(isClearing)

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Watch History")
                    tvClearRow(title: "Clear Watch History", size: nil) {
                        confirmHistoryClear = true
                    }

                    Text("Removes watch progress and the watched status of every title, and empties your Continue Watching and Recently Watched lists. Favorites and your watchlist aren't affected.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
                .disabled(isClearing)
            }
            .task { await load() }
            .clearConfirmations(
                confirmImageClear: $confirmImageClear,
                confirmMetadataClear: $confirmMetadataClear,
                onClearImageCache: { Task { await perform(.imageCache) } },
                onClearMetadata: { Task { await perform(.metadata) } }
            )
            .watchHistoryConfirmation(
                isPresented: $confirmHistoryClear,
                onClear: { Task { await perform(.watchHistory) } }
            )
            #if DEBUG
            .alert("Clear Index", isPresented: $confirmIndexClear) {
                    Button("Clear", role: .destructive) { Task { await perform(.index) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The TMDB metadata and on-device embeddings for every title will be wiped, then re-indexed from scratch in the background.")
                }
            #endif
        }

        private func tvClearRow(title: LocalizedStringKey, size: Int64?, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    Text(title)
                    Spacer(minLength: 0)
                    if let size {
                        Text(verbatim: sizeText(size))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
        }
    #endif
}

// MARK: - Confirmation alerts

private extension View {
    /// The two clear-confirmation alerts, shared by both platform layouts.
    func clearConfirmations(
        confirmImageClear: Binding<Bool>,
        confirmMetadataClear: Binding<Bool>,
        onClearImageCache: @escaping () -> Void,
        onClearMetadata: @escaping () -> Void
    ) -> some View {
        alert("Clear Image Cache", isPresented: confirmImageClear) {
            Button("Clear", role: .destructive, action: onClearImageCache)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded artwork will be removed and re-downloaded when needed.")
        }
        .alert("Clear Metadata Cache", isPresented: confirmMetadataClear) {
            Button("Clear", role: .destructive, action: onClearMetadata)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached posters, cast, trailers and ratings from TMDB and OMDb will be removed. They are re-fetched when you open a movie or show.")
        }
    }

    /// The watch-history clear confirmation, shared by both platform layouts.
    /// Kept separate from `clearConfirmations` because it wipes user data rather
    /// than a re-derivable cache.
    func watchHistoryConfirmation(
        isPresented: Binding<Bool>,
        onClear: @escaping () -> Void
    ) -> some View {
        alert("Clear Watch History", isPresented: isPresented) {
            Button("Clear", role: .destructive, action: onClear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your watch progress and watched status for every title will be removed. This can't be undone.")
        }
    }
}
