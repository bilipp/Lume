//
//  FullScreenPlayerView+Recording.swift
//  Lume
//
//  Resume bookkeeping for recordings, which are not catalog rows and so never
//  go through `WatchProgressWriter`, and the host side of the in-player Record
//  control on a live channel.
//

import SwiftData
import SwiftUI

extension FullScreenPlayerView {
    /// Stores the active recording's position in `RecordingProgressStore` and
    /// returns `true`; returns `false` for anything that is not a recording.
    func persistRecordingProgress() -> Bool {
        guard case let .recording(id) = activeMedia.contentRef else { return false }
        RecordingProgressStore.save(recordingID: id, progress: clock.current, duration: clock.duration)
        return true
    }
}

extension View {
    /// Installs the record flow for the player's Record control and resolves
    /// the channel it acts on, once per stream, so the control never queries
    /// the catalog itself. Polling is left to the control, which is on screen
    /// only while the controls are.
    func playerRecording(for media: PlayableMedia) -> some View {
        modifier(PlayerRecordingModifier(media: media))
    }
}

private struct PlayerRecordingModifier: ViewModifier {
    let media: PlayableMedia

    func body(content: Content) -> some View {
        content
            .modifier(PlayerRecordStreamResolver(media: media))
            .recordActionFlow(observesWhileVisible: false, toastPlacement: Self.toastPlacement)
    }

    /// Every overlay's controls run along the bottom edge, where a toast would
    /// cover them while they are up. The top bar's middle is clear, except on
    /// tvOS, where the toast goes to the trailing corner.
    private static var toastPlacement: RecordActionToastPlacement {
        #if os(tvOS)
            .topTrailing
        #else
            .top
        #endif
    }
}

private struct PlayerRecordStreamResolver: ViewModifier {
    let media: PlayableMedia

    @Environment(\.modelContext) private var modelContext
    @State private var stream: LiveStream?

    func body(content: Content) -> some View {
        content
            .environment(\.playerRecordStream, stream)
            .task(id: media.id) {
                guard media.isLive, case let .live(streamID) = media.contentRef else {
                    stream = nil
                    return
                }
                stream = PlayerContentLookup.liveStream(streamID, in: modelContext)
            }
    }
}
