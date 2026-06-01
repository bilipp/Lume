import SwiftUI

/// A wide episode row: 16:9 still on the left, title / runtime / synopsis on the
/// right, a resume progress bar and a play affordance.
struct EpisodeCard: View {
    let episode: Episode
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 14) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text("E\(episode.episodeNum)" + (episode.title.isEmpty ? "" : " · \(episode.title)"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let minutes = DetailFormat.minutes(episode.durationSecs) {
                        Text(minutes)
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
    }

    private var thumbnail: some View {
        ZStack {
            AsyncImage(url: URL(string: episode.movieImage ?? "")) { phase in
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

            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .opacity(0.9)
        }
    }

    private var resumeFraction: Double? {
        guard episode.watchProgress > 0,
              let duration = episode.durationSecs, duration > 0,
              !episode.isWatched else { return nil }
        return min(episode.watchProgress / Double(duration), 1)
    }
}
