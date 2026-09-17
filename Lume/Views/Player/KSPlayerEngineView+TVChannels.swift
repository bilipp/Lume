//
//  KSPlayerEngineView+TVChannels.swift
//  Lume
//
//  In-player live channel switching for the KSPlayer host on tvOS: Siri-remote
//  channel surfing (up/down/right with the controls hidden) and the two-column
//  channel browser raised by a left press. Split out from the view file to keep
//  it under the SwiftLint file-length threshold; the state these members drive
//  is `internal` (not `private`) so this same-module extension can reach it.
//

#if os(tvOS)

    import SwiftUI

    extension KSPlayerEngineView {
        /// The two-column category / channel browser, slid in over the leading
        /// edge. Picking a channel switches the stream and surfaces the controls
        /// briefly so the new channel's name and EPG act as a banner.
        var channelBrowser: some View {
            TVChannelBrowserOverlay(
                media: media,
                onSelect: { target in
                    onSelectMedia?(target)
                    withAnimation(.easeInOut(duration: 0.25)) { isChannelBrowserOpen = false }
                    showControls()
                },
                onClose: { closeChannelBrowser() }
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
        }

        func openChannelBrowser() {
            guard media.isLive, !isChannelBrowserOpen else { return }
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.25)) { isChannelBrowserOpen = true }
        }

        func closeChannelBrowser() {
            withAnimation(.easeInOut(duration: 0.25)) { isChannelBrowserOpen = false }
            // Hand focus back to the tap-catcher so the remote keeps working.
            Task { @MainActor in catcherFocused = true }
        }

        /// Change the live channel from the Siri Remote — up/down surf the way
        /// the viewer's `LiveSurfMode` maps the press, right recalls the channel
        /// watched just before this one. The swap itself is
        /// `PlayerMediaSwapper`'s, shared with the other three engines and with
        /// the on-screen transport controls.
        func switchLiveChannel(_ direction: MoveCommandDirection) {
            mediaSwapper.surf(
                direction, from: media,
                through: .init(
                    sortRaw: liveContentSortRaw, restriction: restriction, context: modelContext
                ),
                select: { onSelectMedia?($0) },
                showControls: showControls
            )
        }
    }

#endif
