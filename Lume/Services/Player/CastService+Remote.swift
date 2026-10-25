//
//  CastService+Remote.swift
//  Lume
//
//  What the casting remote and the mini-controller read off the receiver, and
//  the play/pause both send it.
//

#if os(iOS)
    import Foundation

    extension CastService {
        /// The item a remote with no player behind it shows.
        var remoteItem: CastRemoteItem {
            CastRemoteItem(status: status, request: currentRequest, media: castingMedia)
        }

        func togglePlayback() {
            if status.isActive {
                pause()
            } else {
                play()
            }
        }
    }
#endif

nonisolated extension CastPlaybackStatus {
    /// Playing, or buffering on its way to playing — what the play/pause
    /// button treats as running.
    var isActive: Bool {
        isPlaying || isBuffering
    }
}
