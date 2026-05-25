//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels — categories sidebar; channels
//  for the selected category are loaded lazily via @Query.
//

import SwiftUI
import SwiftData

struct LiveTVView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "live" && $0.isHidden == false })
    private var categories: [Category]

    @State private var selectedPlaylist: Playlist?
    @State private var selectedCategory: Category?
    @State private var showingSync = false

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add a playlist in Settings to start watching live TV")
                    )
                } else if categories.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("Sync your playlist to load live TV channels")
                        )

                        if let playlist = playlists.first {
                            Button {
                                selectedPlaylist = playlist
                                showingSync = true
                            } label: {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        // Category sidebar
                        CategorySidebar(
                            categories: sortedCategories,
                            selectedCategory: $selectedCategory
                        )
                        .frame(width: 200)

                        Divider()

                        // Channels list (lazy-loaded by category)
                        if let category = selectedCategory {
                            ChannelsList(category: category)
                                .id(category.id)
                        } else {
                            ContentUnavailableView(
                                "Select a Category",
                                systemImage: "list.bullet",
                                description: Text("Choose a category from the sidebar")
                            )
                        }
                    }
                }
            }
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if let playlist = playlists.first {
                        Menu {
                            ForEach(playlists) { p in
                                Button {
                                    selectedPlaylist = p
                                } label: {
                                    Label(p.name, systemImage: selectedPlaylist?.id == p.id ? "checkmark" : "")
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedPlaylist?.name ?? playlist.name)
                                    .font(.headline)
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                        }
                    }
                }

                ToolbarItem(placement: .automatic) {
                    HStack {
                        Button {
                            showingSync = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }

                        Button {
                            // Search action
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            .task {
                if selectedPlaylist == nil, let first = playlists.first {
                    selectedPlaylist = first
                }
                if selectedCategory == nil, let first = sortedCategories.first {
                    selectedCategory = first
                }
            }
            .sheet(isPresented: $showingSync) {
                if let playlist = selectedPlaylist ?? playlists.first {
                    SyncProgressView(playlist: playlist, isPresented: $showingSync)
                }
            }
            .navigationDestination(for: LiveStream.self) { stream in
                // TODO: Create LiveStreamDetailView
                Text("Live Stream: \(stream.name)")
            }
        }
    }

    private var sortedCategories: [Category] {
        categories.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }
}

// MARK: - Category Sidebar

struct CategorySidebar: View {
    let categories: [Category]
    @Binding var selectedCategory: Category?

    var body: some View {
        List(categories) { category in
            Button {
                selectedCategory = category
            } label: {
                HStack {
                    Text(category.name)
                        .font(.headline)
                        .foregroundStyle(selectedCategory?.id == category.id ? Color.accentColor : Color.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
                selectedCategory?.id == category.id
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Channels List

struct ChannelsList: View {
    let category: Category
    @Query private var streams: [LiveStream]

    init(category: Category) {
        self.category = category
        let categoryId = category.id
        _streams = Query(
            filter: #Predicate<LiveStream> { $0.categoryId == categoryId },
            sort: \LiveStream.num
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if streams.isEmpty {
                    ContentUnavailableView(
                        "No Channels",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("This category has no channels")
                    )
                } else {
                    ForEach(streams) { stream in
                        NavigationLink(value: stream) {
                            LiveStreamCardView(stream: stream)
                                .padding(.horizontal)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 88)
                    }
                }
            }
        }
    }
}

#Preview {
    LiveTVView()
        .modelContainer(for: Playlist.self, inMemory: true)
}
