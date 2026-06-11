import SwiftData
import SwiftUI

#if !os(tvOS)

    /// Displays all downloaded movies and episodes and lets the user delete them.
    struct DownloadsView: View {
        @Environment(\.modelContext) private var modelContext

        @Query(
            filter: #Predicate<Movie> { $0.downloadStatusRaw == "completed" },
            sort: \Movie.downloadedAt,
            order: .reverse
        )
        private var downloadedMovies: [Movie]

        @Query(
            filter: #Predicate<Episode> { $0.downloadStatusRaw == "completed" },
            sort: \Episode.downloadedAt,
            order: .reverse
        )
        private var downloadedEpisodes: [Episode]

        @Query private var playlists: [Playlist]

        @State private var downloads = DownloadManager.shared
        @State private var playingMedia: PlayableMedia?
        @State private var itemToDelete: DeletionTarget?

        private var isEmpty: Bool {
            downloadedMovies.isEmpty && downloadedEpisodes.isEmpty && downloads.activeDownloads.isEmpty && downloads.pendingIDs.isEmpty
        }

        var body: some View {
            List {
                inProgressSection
                moviesSection
                episodesSection
            }
            .overlay {
                if isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Downloaded movies and episodes appear here for offline viewing.")
                    )
                }
            }
            .platformNavigationTitle("Downloads")
            #if os(iOS)
                .fullScreenCover(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #elseif os(macOS)
                .sheet(item: $playingMedia) { media in
                    FullScreenPlayerView(media: media)
                }
            #endif
                .confirmationDialog(
                    "Delete Download",
                    isPresented: Binding(
                        get: { itemToDelete != nil },
                        set: { if !$0 { itemToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let target = itemToDelete {
                            downloads.deleteLocalFile(id: target.id)
                            itemToDelete = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { itemToDelete = nil }
                } message: {
                    Text("The downloaded file will be removed. You can re-download it later.")
                }
        }

        // MARK: - Sections

        @ViewBuilder
        private var inProgressSection: some View {
            let inProgress = Array(downloads.activeDownloads.values) + downloads.pendingIDs.map {
                ActiveDownload(id: $0, title: $0, fractionCompleted: 0)
            }
            if !inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(inProgress) { item in
                        ActiveDownloadRow(item: item) {
                            downloads.cancelDownload(id: item.id)
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private var moviesSection: some View {
            if !downloadedMovies.isEmpty {
                Section("Movies") {
                    ForEach(downloadedMovies) { movie in
                        DownloadedMovieRow(movie: movie) {
                            play(movie: movie)
                        } onDelete: {
                            itemToDelete = DeletionTarget(id: movie.id, name: movie.name)
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private var episodesSection: some View {
            if !downloadedEpisodes.isEmpty {
                Section("Episodes") {
                    ForEach(downloadedEpisodes) { episode in
                        DownloadedEpisodeRow(episode: episode) {
                            play(episode: episode)
                        } onDelete: {
                            itemToDelete = DeletionTarget(id: episode.id, name: episode.title)
                        }
                    }
                }
            }
        }

        // MARK: - Playback

        private func play(movie: Movie) {
            // Try local file first, then fall back to streaming via the playlist
            if let path = movie.localFileURL, FileManager.default.fileExists(atPath: path) {
                playingMedia = PlayableMedia(
                    id: "movie-\(movie.id)",
                    url: URL(fileURLWithPath: path),
                    title: movie.name,
                    subtitle: movie.releaseDate,
                    posterURL: URL(string: movie.streamIcon ?? ""),
                    kind: .vod,
                    startTime: movie.watchProgress,
                    contentRef: .movie(movie.id)
                )
                return
            }
            guard let playlist = playlists.first(where: { movie.id.hasPrefix($0.id.uuidString) }) ?? playlists.first,
                  let media = PlayableMedia.from(movie: movie, playlist: playlist)
            else { return }
            playingMedia = media
        }

        private func play(episode: Episode) {
            if let path = episode.localFileURL, FileManager.default.fileExists(atPath: path) {
                let seriesName = episode.series?.name
                playingMedia = PlayableMedia(
                    id: "episode-\(episode.id)",
                    url: URL(fileURLWithPath: path),
                    title: seriesName ?? episode.title,
                    subtitle: "S\(episode.seasonNum) E\(episode.episodeNum) · \(episode.title)",
                    posterURL: URL(string: episode.movieImage ?? ""),
                    kind: .vod,
                    startTime: episode.watchProgress,
                    contentRef: .episode(episode.id)
                )
                return
            }
            guard let series = episode.series,
                  let playlist = playlists.first(where: { series.id.hasPrefix($0.id.uuidString) }) ?? playlists.first,
                  let media = PlayableMedia.from(episode: episode, playlist: playlist)
            else { return }
            playingMedia = media
        }
    }

    // MARK: - Row views

    private struct ActiveDownloadRow: View {
        let item: ActiveDownload
        let onCancel: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if item.fractionCompleted > 0 {
                        ProgressView(value: item.fractionCompleted)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    private struct DownloadedMovieRow: View {
        let movie: Movie
        let onPlay: () -> Void
        let onDelete: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                CachedAsyncImage(url: URL(string: movie.streamIcon ?? ""), maxPixelSize: 60) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.gray.opacity(0.25))
                            .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(movie.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let date = movie.downloadedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    fileSizeLabel(path: movie.localFileURL)
                }

                Spacer(minLength: 0)

                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    private struct DownloadedEpisodeRow: View {
        let episode: Episode
        let onPlay: () -> Void
        let onDelete: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                CachedAsyncImage(url: URL(string: episode.movieImage ?? ""), maxPixelSize: 100) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.gray.opacity(0.25))
                            .overlay {
                                Text("E\(episode.episodeNum)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 70, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    if let seriesName = episode.series?.name {
                        Text(seriesName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("S\(episode.seasonNum) E\(episode.episodeNum) · \(episode.title)")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let date = episode.downloadedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    fileSizeLabel(path: episode.localFileURL)
                }

                Spacer(minLength: 0)

                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fileSizeLabel(path: String?) -> some View {
        if let path, let size = fileSize(at: path) {
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fileSize(at path: String) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? Int64
    }

    private struct DeletionTarget: Identifiable {
        let id: String
        let name: String
    }

#endif
