//
//  CastPlaybackView.swift
//  Lume
//
//  The remote the player shows while a Chromecast plays: artwork, title,
//  transport, scrubber, receiver volume and Stop Casting.
//
//  Two modes. Driven by the full-screen player, it shows the player's media
//  and reads the player's `PlaybackClock`, which `PlayerCastSession` feeds
//  from the receiver. Status-only — a session the SDK resumed at launch, with
//  no `PlayableMedia` in memory — it shows the mini-controller's item and
//  clock, which follow `CastService`'s receiver status.
//

#if os(iOS)
    import SwiftUI

    struct CastPlaybackView: View {
        private let media: PlayableMedia?
        private let clock: PlaybackClock
        private let receiver: CastMiniControllerModel?
        private let neighbours: PlayerItemNavigation.Neighbours
        private let onStep: (PlayerMediaSwapper.Step) -> Void
        private let onStop: () -> Void
        private let onClose: () -> Void

        @State private var castService = CastService.shared
        @State private var isSeeking = false
        @State private var seekPosition: TimeInterval = 0
        @Environment(\.verticalSizeClass) private var verticalSizeClass

        /// Driven by the full-screen player, whose cast session keeps `clock`
        /// on the receiver's position.
        init(
            media: PlayableMedia,
            clock: PlaybackClock,
            neighbours: PlayerItemNavigation.Neighbours,
            onStep: @escaping (PlayerMediaSwapper.Step) -> Void,
            onStop: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            self.media = media
            self.clock = clock
            receiver = nil
            self.neighbours = neighbours
            self.onStep = onStep
            self.onStop = onStop
            self.onClose = onClose
        }

        /// Status-only, for a receiver session with no player behind it.
        init(receiver: CastMiniControllerModel, onStop: @escaping () -> Void, onClose: @escaping () -> Void) {
            media = nil
            clock = receiver.clock
            self.receiver = receiver
            neighbours = .none
            onStep = { _ in }
            self.onStop = onStop
            self.onClose = onClose
        }

        var body: some View {
            Group {
                if isCompact {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { backdrop }
            .overlay(alignment: .topLeading) { closeButton }
        }

        private var item: CastRemoteItem {
            if let media {
                CastRemoteItem(media: media)
            } else {
                receiver?.item ?? .empty
            }
        }

        private var isCompact: Bool {
            verticalSizeClass == .compact
        }

        private var deviceHeader: some View {
            Label {
                CastingDeviceLabel(castService: castService)
            } icon: {
                Image(systemName: "tv.badge.wifi")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
        }

        // MARK: - Layouts

        private var portraitLayout: some View {
            VStack(spacing: 22) {
                deviceHeader
                Spacer(minLength: 0)
                artwork
                    .frame(maxHeight: 300)
                titleBlock
                Spacer(minLength: 0)
                timeline
                transport
                CastVolumeSlider(castService: castService)
                stopButton
            }
            .frame(maxWidth: 520)
        }

        private var landscapeLayout: some View {
            HStack(spacing: 32) {
                artwork
                    .frame(maxWidth: 240, maxHeight: .infinity)
                VStack(spacing: 14) {
                    deviceHeader
                    titleBlock
                    timeline
                    transport
                    HStack(spacing: 20) {
                        CastVolumeSlider(castService: castService)
                        stopButton
                    }
                }
                .frame(maxWidth: 560)
            }
        }

        // MARK: - Pieces

        private var backdrop: some View {
            Color.black
                .overlay {
                    CachedAsyncImage(url: item.posterURL, maxPixelSize: 200) { phase in
                        if case let .success(image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 40)
                                .opacity(0.45)
                        }
                    }
                }
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.2), .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }

        private var artwork: some View {
            CachedAsyncImage(url: item.posterURL, maxPixelSize: 600) { phase in
                if case let .success(image) = phase {
                    image
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 150, height: 150)
                        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
            }
            .accessibilityHidden(true)
        }

        private var titleBlock: some View {
            VStack(spacing: 4) {
                if !item.title.isEmpty {
                    Text(item.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }

        @ViewBuilder
        private var timeline: some View {
            if item.isLive {
                LiveBadge(fontSize: 12)
            } else {
                VStack(spacing: 6) {
                    PlaybackTimeline(
                        clock: clock,
                        timeline: nil,
                        isSeeking: $isSeeking,
                        seekPosition: $seekPosition,
                        onEditingChanged: scrubbed
                    )
                }
            }
        }

        private var transport: some View {
            ViewThatFits(in: .horizontal) {
                transportRow(spacing: 28)
                transportRow(spacing: 12)
            }
        }

        private func transportRow(spacing: CGFloat) -> some View {
            HStack(spacing: spacing) {
                if neighbours.axis != nil {
                    PlayerItemNavButton(step: .previous, neighbours: neighbours, onStep: onStep, onResetHideTimer: {})
                }
                if !item.isLive {
                    skipButton(by: -15, systemName: "gobackward.15")
                        .accessibilityLabel("Skip back 15 seconds")
                }
                CastPlayPauseButton(castService: castService, diameter: isCompact ? 64 : 76)
                if !item.isLive {
                    skipButton(by: 15, systemName: "goforward.15")
                        .accessibilityLabel("Skip forward 15 seconds")
                }
                if neighbours.axis != nil {
                    PlayerItemNavButton(step: .next, neighbours: neighbours, onStep: onStep, onResetHideTimer: {})
                }
            }
        }

        private func skipButton(by interval: TimeInterval, systemName: String) -> some View {
            Button {
                let duration = clock.duration
                var target = max(0, clock.current + interval)
                if duration > 0 {
                    target = min(target, duration)
                }
                castService.seek(to: target)
                clock.current = target
            } label: {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
                    .glassEffectCompat(.regularInteractive, in: Circle())
            }
            .buttonStyle(.plain)
        }

        private var stopButton: some View {
            Button(action: onStop) {
                Label {
                    Text(CastLabels.stop)
                } icon: {
                    Image(systemName: "stop.fill")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .contentShape(Capsule())
                .glassEffectCompat(.regularInteractive, in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }

        private var closeButton: some View {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffectCompat(.regularInteractive, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .accessibilityLabel("Close player")
            .keyboardShortcut(.escape, modifiers: [])
        }

        private func scrubbed(editing: Bool) {
            if editing {
                seekPosition = clock.current
                isSeeking = true
            } else {
                castService.seek(to: seekPosition)
                clock.current = seekPosition
                isSeeking = false
            }
        }
    }

    // MARK: - Receiver-driven state

    /// What the remote shows about the item on the receiver.
    nonisolated struct CastRemoteItem: Hashable {
        var title: String
        var subtitle: String?
        var posterURL: URL?
        var isLive: Bool

        static let empty = CastRemoteItem(title: "", subtitle: nil, posterURL: nil, isLive: false)
    }

    nonisolated extension CastRemoteItem {
        init(media: PlayableMedia) {
            self.init(title: media.title, subtitle: media.subtitle, posterURL: media.posterURL, isLive: media.isLive)
        }

        /// The item for a remote with no player behind it: the stream Lume
        /// loaded when it still knows it, else the receiver's own metadata. A
        /// receiver reports no duration for live streams.
        init(status: CastPlaybackStatus, request: CastMediaRequest?, media: PlayableMedia?) {
            if let media {
                self.init(media: media)
            } else if let request {
                self.init(
                    title: request.title,
                    subtitle: request.subtitle,
                    posterURL: request.posterURL,
                    isLive: request.streamType == .live
                )
            } else {
                self.init(
                    title: status.title ?? "",
                    subtitle: status.subtitle,
                    posterURL: status.posterURL,
                    isLive: status.hasMedia && status.duration == nil
                )
            }
        }
    }

    // MARK: - Status leaves

    private struct CastPlayPauseButton: View {
        let castService: CastService
        let diameter: CGFloat

        var body: some View {
            let isPlaying = castService.isReceiverPlaying
            let glyph = isPlaying ? "pause.fill" : "play.fill"
            Button(action: castService.togglePlayback) {
                Image(systemName: glyph)
                    .symbolReplaceTransition(value: glyph)
                    .font(.system(size: diameter * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
                    .glassEffectCompat(.regularInteractive, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
    }

    /// The receiver's volume. Holds the dragged value until the receiver
    /// reports it back, so the knob doesn't snap to the stale level between.
    private struct CastVolumeSlider: View {
        let castService: CastService

        @State private var draggedVolume: Double?
        @State private var isDragging = false
        @State private var lastVolumeSend = Date.distantPast

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { draggedVolume ?? Double(castService.receiverVolume) },
                        set: { volume in
                            draggedVolume = volume
                            // Each send is a network message to the receiver.
                            let now = Date.now
                            if now.timeIntervalSince(lastVolumeSend) >= 0.2 {
                                lastVolumeSend = now
                                castService.setVolume(Float(volume))
                            }
                        }
                    ),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing, let draggedVolume {
                            castService.setVolume(Float(draggedVolume))
                        }
                    }
                )
                .tint(.white)
                .accessibilityLabel(Text(Self.label))
                Image(systemName: "speaker.wave.3.fill")
                    .accessibilityHidden(true)
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.8))
            .onChange(of: castService.receiverVolume) {
                if !isDragging {
                    draggedVolume = nil
                }
            }
        }

        private static let label = LocalizedStringResource(
            "player.cast.volume",
            defaultValue: "Volume",
            comment: "Player › Casting: accessibility label of the slider that sets the Chromecast's volume."
        )
    }
#endif
