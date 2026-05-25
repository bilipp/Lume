//
//  SeriesDetailView.swift
//  Lume
//
//  Detailed view for a series with season/episode selection
//

import SwiftUI
import SwiftData

struct SeriesDetailView: View {
    let series: Series

    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]

    @State private var selectedSeason: Int = 1
    @State private var isLoadingEpisodes = false
    @State private var showingPlayer = false
    @State private var selectedEpisode: Episode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with cover
                HStack(alignment: .top, spacing: 20) {
                    // Cover
                    AsyncImage(url: URL(string: series.cover ?? "")) { phase in
                        switch phase {
                        case .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay {
                                    ProgressView()
                                }
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay {
                                    Image(systemName: "tv")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 40))
                                }
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 150, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 4)

                    VStack(alignment: .leading, spacing: 12) {
                        // Title
                        Text(series.name)
                            .font(.title2)
                            .fontWeight(.bold)

                        // Release Date
                        if let releaseDate = series.releaseDate {
                            Text(releaseDate)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Rating
                        if let ratingString = series.rating, let rating = Double(ratingString), rating > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text(String(format: "%.1f", rating))
                                    .fontWeight(.semibold)
                                Text("/ 10")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }

                        // Genre
                        if let genre = series.genre {
                            Text(genre)
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding()

                // Action Buttons
                HStack(spacing: 16) {
                    ActionButton(
                        icon: series.isFavorite ? "heart.fill" : "heart",
                        title: "Favorite",
                        action: { toggleFavorite() }
                    )

                    ActionButton(
                        icon: "square.and.arrow.down",
                        title: "Download",
                        action: { /* TODO */ }
                    )
                }
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                // Description
                if let plot = series.plot, !plot.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)
                        Text(plot)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                // Cast and Crew
                if let cast = series.cast, !cast.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cast")
                            .font(.headline)
                        Text(cast)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                if let director = series.director, !director.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Director")
                            .font(.headline)
                        Text(director)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                Divider()
                    .padding(.horizontal)

                // Episodes Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Episodes")
                        .font(.headline)
                        .padding(.horizontal)

                    // Season Picker
                    if !availableSeasons.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(availableSeasons, id: \.self) { season in
                                    Button {
                                        selectedSeason = season
                                    } label: {
                                        Text("Season \(season)")
                                            .font(.subheadline)
                                            .fontWeight(selectedSeason == season ? .semibold : .regular)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(
                                                selectedSeason == season
                                                    ? Color.blue
                                                    : Color.gray.opacity(0.2)
                                            )
                                            .foregroundStyle(
                                                selectedSeason == season
                                                    ? .white
                                                    : .primary
                                            )
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Episodes List
                    if series.episodes.isEmpty {
                        VStack(spacing: 16) {
                            if isLoadingEpisodes {
                                ProgressView()
                                Text("Loading episodes…")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No episodes available")
                                    .foregroundStyle(.secondary)

                                Button {
                                    loadEpisodes()
                                } label: {
                                    Text("Retry")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(seasonEpisodes) { episode in
                                EpisodeRow(episode: episode) {
                                    selectedEpisode = episode
                                    showingPlayer = true
                                }

                                if episode.id != seasonEpisodes.last?.id {
                                    Divider()
                                        .padding(.leading, 100)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if series.episodes.isEmpty && !isLoadingEpisodes {
                loadEpisodes()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    series.isFavorite.toggle()
                } label: {
                    Image(systemName: series.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(series.isFavorite ? .red : .primary)
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingPlayer) {
            if let episode = selectedEpisode, let playlist = playlists.first {
                PlayerView(content: episode, playlist: playlist)
            }
        }
        #else
        .sheet(isPresented: $showingPlayer) {
            if let episode = selectedEpisode, let playlist = playlists.first {
                PlayerView(content: episode, playlist: playlist)
            }
        }
        #endif
    }

    private var availableSeasons: [Int] {
        let seasons = Set(series.episodes.map { $0.seasonNum })
        return seasons.sorted()
    }

    private var seasonEpisodes: [Episode] {
        series.episodes
            .filter { $0.seasonNum == selectedSeason }
            .sorted { $0.episodeNum < $1.episodeNum }
    }

    private func toggleFavorite() {
        series.isFavorite.toggle()
    }

    private func loadEpisodes() {
        guard let playlist = playlists.first else { return }

        isLoadingEpisodes = true

        Task {
            do {
                let syncManager = ContentSyncManager(modelContainer: modelContext.container)
                try await syncManager.syncEpisodes(for: series, playlist: playlist)

                await MainActor.run {
                    isLoadingEpisodes = false
                }
            } catch {
                await MainActor.run {
                    isLoadingEpisodes = false
                }
            }
        }
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: Episode
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                // Episode thumbnail
                if let imageURL = episode.movieImage {
                    AsyncImage(url: URL(string: imageURL)) { phase in
                        switch phase {
                        case .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay {
                                    ProgressView()
                                }
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay {
                                    Image(systemName: "tv")
                                        .foregroundStyle(.secondary)
                                }
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            Text("E\(episode.episodeNum)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("E\(episode.episodeNum): \(episode.title)")
                        .font(.headline)
                        .lineLimit(2)

                    if let duration = episode.durationSecs {
                        Text(formatDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Progress bar
                    if episode.watchProgress > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(height: 3)

                                if let duration = episode.durationSecs, duration > 0 {
                                    Rectangle()
                                        .fill(Color.blue)
                                        .frame(
                                            width: geometry.size.width * (episode.watchProgress / Double(duration)),
                                            height: 3
                                        )
                                }
                            }
                        }
                        .frame(height: 3)
                    }
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .padding()
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes)m"
    }
}

#Preview {
    NavigationStack {
        SeriesDetailView(
            series: Series(
                id: "preview",
                seriesId: 1,
                name: "Sample Series"
            )
        )
    }
    .modelContainer(for: Playlist.self, inMemory: true)
}
