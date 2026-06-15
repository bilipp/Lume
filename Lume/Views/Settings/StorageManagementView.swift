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

    private enum ClearAction {
        case imageCache, metadata
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
            StorageManager.clearMetadataEnrichment(in: modelContext)
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
            }
            .platformNavigationTitle("Storage & Cache")
            .task { await load() }
            .clearConfirmations(
                confirmImageClear: $confirmImageClear,
                confirmMetadataClear: $confirmMetadataClear,
                onClearImageCache: { Task { await perform(.imageCache) } },
                onClearMetadata: { Task { await perform(.metadata) } }
            )
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
            }
            .task { await load() }
            .clearConfirmations(
                confirmImageClear: $confirmImageClear,
                confirmMetadataClear: $confirmMetadataClear,
                onClearImageCache: { Task { await perform(.imageCache) } },
                onClearMetadata: { Task { await perform(.metadata) } }
            )
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
}
