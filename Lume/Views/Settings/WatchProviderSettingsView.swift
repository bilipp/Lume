//
//  WatchProviderSettingsView.swift
//  Lume
//
//  Lets the user pick which streaming services ("watch providers") the Movies
//  and Series tabs group content by. The provider catalog is fetched from TMDB
//  for the user's region and cached locally; selection is held by
//  `WatchProviderSettings`.
//

import SwiftData
import SwiftUI

struct WatchProviderSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WatchProvider.displayPriority) private var providers: [WatchProvider]
    @State private var settings = WatchProviderSettings.shared
    @State private var isRefreshing = false

    private var isConfigured: Bool {
        TMDBClient.shared.isConfigured
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    // MARK: - Catalog refresh

    /// Pulls the region's provider list from TMDB and upserts it into the local
    /// catalog. Existing rows are updated in place so selection ids stay valid.
    private func refresh() async {
        guard isConfigured, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let manager = ContentSyncManager(modelContainer: modelContext.container)
        let fetched = await manager.fetchWatchProviderList()
        guard !fetched.isEmpty else { return }

        let existing = (try? modelContext.fetch(FetchDescriptor<WatchProvider>())) ?? []
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for info in fetched {
            if let provider = byId[info.id] {
                provider.name = info.name
                provider.logoPath = info.logoPath
                provider.displayPriority = info.displayPriority
            } else {
                let provider = WatchProvider(
                    id: info.id,
                    name: info.name,
                    logoPath: info.logoPath,
                    displayPriority: info.displayPriority
                )
                modelContext.insert(provider)
                byId[info.id] = provider
            }
        }
        try? modelContext.save()
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
        private var standardBody: some View {
            List {
                Section {
                    if !isConfigured {
                        Text("Streaming providers are unavailable because TMDB is not configured in this build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if providers.isEmpty {
                        HStack {
                            Spacer()
                            if isRefreshing {
                                ProgressView()
                            } else {
                                Text("No providers loaded yet.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    } else {
                        ForEach(providers) { provider in
                            Button {
                                settings.toggle(provider.id)
                            } label: {
                                providerRow(provider)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Pick the streaming services you subscribe to. The Movies and Series tabs add a section for each, grouping titles available on that service in your region.")
                }
            }
            .navigationTitle("Streaming Providers")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!isConfigured || isRefreshing)
                }
            }
            .task {
                if providers.isEmpty { await refresh() }
            }
        }

        private func providerRow(_ provider: WatchProvider) -> some View {
            HStack(spacing: 12) {
                providerLogo(provider)
                Text(provider.name)
                Spacer()
                Image(systemName: settings.isSelected(provider.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(settings.isSelected(provider.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
        }
    #endif

    // MARK: - tvOS (settings detail pane)

    #if os(tvOS)
        private var tvBody: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TVSettingsSectionLabel("Streaming Providers")
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .disabled(!isConfigured || isRefreshing)
                }

                Text("Pick the streaming services you subscribe to. The Movies and Series tabs add a section for each, grouping titles available on that service in your region.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.bottom, 8)

                if !isConfigured {
                    Text("Streaming providers are unavailable because TMDB is not configured in this build.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                } else if providers.isEmpty {
                    Text(isRefreshing ? "Loading providers…" : "No providers loaded yet.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                } else {
                    VStack(spacing: 2) {
                        ForEach(providers) { provider in
                            Button {
                                settings.toggle(provider.id)
                            } label: {
                                HStack(spacing: 16) {
                                    providerLogo(provider)
                                    Text(provider.name)
                                    Spacer(minLength: 0)
                                    Text(settings.isSelected(provider.id) ? "On" : "Off")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(TVSettingsRowButtonStyle())
                        }
                    }
                }
            }
            .task {
                if providers.isEmpty { await refresh() }
            }
        }
    #endif

    // MARK: - Shared

    private func providerLogo(_ provider: WatchProvider) -> some View {
        CachedAsyncImage(url: TMDBClient.providerLogoURL(provider.logoPath), maxPixelSize: logoSize * 2) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fit)
            default:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.3))
                    .overlay {
                        Image(systemName: "play.tv")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: logoSize, height: logoSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var logoSize: CGFloat {
        #if os(tvOS)
            48
        #else
            40
        #endif
    }
}
