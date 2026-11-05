import SwiftUI

/// Keeps the experimental Mac path out of the shared engine-selection switch.
struct TimeshiftPlayerAdapter<Content: View>: View {
    let media: PlayableMedia
    let clock: PlaybackClock
    @ViewBuilder let content: (PlayableMedia) -> Content

    var body: some View {
        #if os(macOS)
            if TimeshiftEligibility.allows(isLive: media.isLive, url: media.url,
                                           enabled: UserDefaults.standard.bool(forKey: "player.timeshift.experimental"))
            {
                TimeshiftPlayerHost(media: media, clock: clock, content: content)
                    .id(media.url)
            } else {
                content(media)
            }
        #else
            content(media)
        #endif
    }
}
