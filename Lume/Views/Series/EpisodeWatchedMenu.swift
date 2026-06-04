import SwiftUI

/// Context-menu contents shared by the iOS/macOS `EpisodeCard` and the tvOS
/// `TVEpisodeCard`: toggle this episode's watched state, and bulk-update the
/// episodes ordered before or after it. The neighbour actions only appear when
/// such episodes actually exist.
struct EpisodeWatchedMenu: View {
    let episode: Episode
    var onToggleWatched: () -> Void
    var onMarkPreviousWatched: () -> Void
    var onMarkFollowingUnwatched: () -> Void

    var body: some View {
        Button {
            onToggleWatched()
        } label: {
            Label(
                episode.isWatched ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: episode.isWatched ? "eye.slash" : "checkmark.circle"
            )
        }

        if episode.hasEarlierEpisodes {
            Button {
                onMarkPreviousWatched()
            } label: {
                Label("Mark All Previous as Watched", systemImage: "checkmark.circle.fill")
            }
        }

        if episode.hasLaterWatchedEpisodes {
            Button {
                onMarkFollowingUnwatched()
            } label: {
                Label("Mark All Following as Unwatched", systemImage: "arrow.counterclockwise.circle")
            }
        }
    }
}
