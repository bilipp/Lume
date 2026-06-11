import SwiftUI

/// A wide episode row: 16:9 still on the left, title / runtime / synopsis on the
/// right, a resume progress bar and a play affordance.
struct EpisodeCard: View {
    let episode: Episode
    var onPlay: () -> Void
    var onToggleWatched: () -> Void = {}
    var onMarkPreviousWatched: () -> Void = {}
    var onMarkFollowingUnwatched: () -> Void = {}
    #if !os(tvOS)
        var onDownload: (() -> Void)?
        var onDeleteDownload: (() -> Void)?
        var downloadProgress: Double?
    #endif

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 14) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text("E\(episode.episodeNum)" + (episode.title.isEmpty ? "" : " · \(episode.title)"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let metaLine {
                        Text(metaLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let plot = episode.plot, !plot.isEmpty {
                        Text(plot)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let progress = resumeFraction {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            EpisodeWatchedMenu(
                episode: episode,
                onToggleWatched: onToggleWatched,
                onMarkPreviousWatched: onMarkPreviousWatched,
                onMarkFollowingUnwatched: onMarkFollowingUnwatched
            )
            #if !os(tvOS)
                Divider()
                if episode.downloadStatus == .completed {
                    Button(role: .destructive) {
                        onDeleteDownload?()
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else if downloadProgress == nil {
                    Button {
                        onDownload?()
                    } label: {
                        Label("Download Episode", systemImage: "arrow.down.circle")
                    }
                    .disabled(onDownload == nil)
                } else {
                    Button(role: .destructive) {
                        onDeleteDownload?()
                    } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                }
            #endif
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            CachedAsyncImage(url: URL(string: episode.movieImage ?? ""), maxPixelSize: 142) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty where episode.movieImage != nil:
                    Rectangle().fill(Color.gray.opacity(0.25)).overlay { ProgressView() }
                default:
                    Rectangle().fill(Color.gray.opacity(0.25))
                        .overlay {
                            Text("E\(episode.episodeNum)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 142, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            #if !os(tvOS)
                if let progress = downloadProgress {
                    // Actively downloading: show a progress indicator
                    ZStack {
                        Rectangle()
                            .fill(.black.opacity(0.45))
                        if progress > 0 {
                            ProgressView(value: progress)
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.6)
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.6)
                        }
                    }
                    .frame(width: 142, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if episode.downloadStatus == .completed {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.tint.opacity(0.85), in: Circle())
                        .padding(5)
                }
            #endif

            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .opacity(0.9)
                .frame(width: 142, height: 80)
        }
        .frame(width: 142, height: 80)
    }

    /// Air date and runtime joined on a single caption line, omitting whichever is missing.
    private var metaLine: String? {
        let parts = [
            DetailFormat.date(from: episode.airDate),
            DetailFormat.minutes(episode.durationSecs)
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var resumeFraction: Double? {
        guard episode.watchProgress > 0,
              let duration = episode.durationSecs, duration > 0,
              !episode.isWatched else { return nil }
        return min(episode.watchProgress / Double(duration), 1)
    }
}
