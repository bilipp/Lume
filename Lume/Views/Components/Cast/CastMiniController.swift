//
//  CastMiniController.swift
//  Lume
//
//  The "Now Casting" bar above the tab bar while a Chromecast plays with no
//  player on screen: artwork, title, "Casting to <device>", play/pause and
//  stop. A tap reopens the full-screen player on the stream when Lume still
//  has it in memory, else the status-only casting remote — a session the SDK
//  resumed at launch.
//
//  Where the bar sits is `CastMiniControllerPlacement`'s job; this file owns what
//  it shows and the state behind it.
//

import SwiftUI

/// When the mini-controller shows.
nonisolated enum CastMiniControllerPolicy {
    /// While a Chromecast plays something and no open player shows the cast.
    /// A receiver that went idle has nothing to control.
    static func isVisible(
        connection: CastConnectionState,
        hasLoadedMedia: Bool,
        receiverHasMedia: Bool,
        playerIsVisible: Bool
    ) -> Bool {
        connection == .connected && (hasLoadedMedia || receiverHasMedia) && !playerIsVisible
    }
}

#if os(iOS)
    /// The mini-controller's state, owned by the tab root and shared with
    /// every bar instance. Follows the receiver status through `CastService`'s
    /// observer and republishes only what changed, so no view body reads the
    /// per-second receiver position — only the status-only remote's `clock`
    /// moves with it.
    @MainActor
    @Observable
    final class CastMiniControllerModel {
        @ObservationIgnored let castService: CastService
        @ObservationIgnored let clock = PlaybackClock()
        private(set) var item = CastRemoteItem.empty
        private(set) var isPlaying = false
        private(set) var receiverHasMedia = false

        /// Whether the status-only casting remote is up.
        var showsRemote = false

        @ObservationIgnored private let owner = "cast-mini-controller-\(UUID().uuidString)"
        @ObservationIgnored private let openPlayer: (PlayableMedia) -> Void

        init(castService: CastService? = nil, openPlayer: @escaping (PlayableMedia) -> Void) {
            self.castService = castService ?? .shared
            self.openPlayer = openPlayer
        }

        var isVisible: Bool {
            CastMiniControllerPolicy.isVisible(
                connection: castService.chromecastConnection,
                hasLoadedMedia: castService.currentRequest != nil,
                receiverHasMedia: receiverHasMedia,
                playerIsVisible: castService.isHostedByPlayer
            )
        }

        func start() {
            refresh()
            castService.observeStatus(owner: owner) { [weak self] _ in self?.refresh() }
        }

        func stop() {
            castService.removeStatusObserver(owner: owner)
        }

        func refresh() {
            let status = castService.status
            let newItem = castService.remoteItem
            if newItem != item {
                item = newItem
            }
            let playing = status.isActive
            if playing != isPlaying {
                isPlaying = playing
            }
            if status.hasMedia != receiverHasMedia {
                receiverHasMedia = status.hasMedia
            }
            if let reading = PlayerCastPolicy.clockReading(for: status, isLive: newItem.isLive) {
                clock.apply(reading)
            }
        }

        func open() {
            if let media = castService.castingMedia {
                openPlayer(media)
            } else {
                showsRemote = true
            }
        }

        func togglePlayback() {
            castService.togglePlayback()
        }

        func stopCasting() {
            castService.endSession(stopReceiver: true)
        }
    }

    /// The bar's content. `isInline` is the iOS 26 accessory squeezed beside
    /// a minimized tab bar, where only the title line fits.
    struct CastMiniControllerBar: View {
        let model: CastMiniControllerModel
        var isInline = false

        var body: some View {
            HStack(spacing: 4) {
                Button(action: model.open) {
                    HStack(spacing: 10) {
                        artwork
                        labels
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(Self.openHint))

                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .symbolReplaceTransition(value: model.isPlaying)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Button(action: model.stopCasting) {
                    Image(systemName: "stop.fill")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CastLabels.stop))
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
        }

        private var artwork: some View {
            CachedAsyncImage(url: model.item.posterURL, maxPixelSize: 120) { phase in
                if case let .success(image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "tv")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: isInline ? 28 : 36, height: isInline ? 28 : 36)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
        }

        @ViewBuilder
        private var labels: some View {
            let title = model.item.title
            VStack(alignment: .leading, spacing: 1) {
                if !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                if title.isEmpty || !isInline {
                    CastingDeviceLabel(castService: model.castService)
                        .font(title.isEmpty ? .subheadline.weight(.semibold) : .caption)
                        .foregroundStyle(title.isEmpty ? .primary : .secondary)
                }
            }
            .lineLimit(1)
        }

        private static let openHint = LocalizedStringResource(
            "cast.mini-controller.open-hint",
            defaultValue: "Opens the casting controls.",
            comment: "Tab bar › Casting mini-controller: accessibility hint of the bar that shows what a Chromecast is playing."
        )
    }
#endif
