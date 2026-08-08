//
//  ChromecastPlaybackView.swift
//  Lume
//
//  The player's face while a Chromecast session is active. The local engine is
//  unmounted for the duration of the cast — decoding the stream on the phone
//  while the receiver plays it would burn battery for pixels nobody sees — so
//  this view stands in with the poster, the receiver's name, and a transport
//  that drives the receiver through the `CastProvider` seam.
//
//  The receiver's playhead is polled into the shared `PlaybackClock` (the Cast
//  SDK only pushes media status on change, not per tick), which keeps the
//  scrubber moving and — because `FullScreenPlayerView` persists watch progress
//  from that same clock at the usual boundaries — resume points and the
//  90%-watched flow keep working while casting, no extra bridging needed.
//
//  iOS-only: the Google Cast SDK has no other Apple platform, so the provider
//  seam this view drives is never populated elsewhere (see `Docs/Chromecast.md`).
//

#if os(iOS)
    import SwiftUI

    struct ChromecastPlaybackView: View {
        let media: PlayableMedia
        var clock: PlaybackClock

        @State private var castService = CastService.shared
        @State private var isPlaying = true
        @State private var isSeeking = false
        @State private var seekPosition: TimeInterval = 0

        private var provider: (any CastProvider)? {
            castService.castProvider
        }

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 28) {
                    poster
                    deviceLine
                    transport
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    HStack {
                        Spacer()
                        ChromecastButton()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    Spacer()
                    bottomBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                }
            }
            .task { await followReceiver() }
        }

        // MARK: - Artwork & Device

        private var poster: some View {
            CachedAsyncImage(url: media.posterURL, maxPixelSize: 320) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.08))
                        .overlay {
                            Image(systemName: "tv")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .aspectRatio(2 / 3, contentMode: .fit)
                }
            }
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        }

        private var deviceLine: some View {
            VStack(spacing: 6) {
                Text(media.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Label {
                    Text("Casting to \(provider?.connectedDeviceName ?? "Chromecast")")
                } icon: {
                    Image(systemName: "tv.badge.wifi")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            }
            .multilineTextAlignment(.center)
        }

        // MARK: - Transport

        private var transport: some View {
            HStack(spacing: 32) {
                if !media.isLive {
                    Button {
                        seekReceiver(to: clock.current - 15)
                    } label: {
                        circleGlyph("gobackward.15", size: 22, diameter: 60)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip back 15 seconds")
                }

                Button {
                    if isPlaying {
                        provider?.pause()
                    } else {
                        provider?.play()
                    }
                    // Optimistic flip; the receiver poll corrects it if the
                    // command didn't take.
                    isPlaying.toggle()
                } label: {
                    circleGlyph(isPlaying ? "pause.fill" : "play.fill", size: 30, diameter: 76)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                if !media.isLive {
                    Button {
                        seekReceiver(to: clock.current + 15)
                    } label: {
                        circleGlyph("goforward.15", size: 22, diameter: 60)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward 15 seconds")
                }
            }
        }

        @ViewBuilder
        private var bottomBar: some View {
            if media.isLive {
                HStack(spacing: 7) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                timeline
            }
        }

        private var timeline: some View {
            VStack(spacing: 4) {
                Slider(
                    value: Binding<TimeInterval>(
                        get: { isSeeking ? seekPosition : clock.current },
                        set: { seekPosition = $0 }
                    ),
                    in: 0 ... max(clock.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            seekPosition = clock.current
                            isSeeking = true
                        } else {
                            seekReceiver(to: seekPosition)
                            isSeeking = false
                        }
                    }
                )
                .tint(.white)

                HStack {
                    Text(timeString(from: isSeeking ? seekPosition : clock.current))
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                    Spacer()
                    Text(timeString(from: clock.duration))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.caption.monospacedDigit())
            }
        }

        // MARK: - Receiver Bridging

        /// Poll the receiver's transport into the shared clock and the
        /// play/pause state. Half a second keeps the scrubber visually smooth
        /// without meaningful cost — each tick reads three cached values off
        /// the Cast SDK's last media status.
        private func followReceiver() async {
            while !Task.isCancelled {
                if let provider {
                    if !isSeeking {
                        let position = provider.approximatePosition
                        if position > 0 { clock.current = position }
                        let duration = provider.streamDuration
                        if duration > 0 { clock.duration = duration }
                    }
                    isPlaying = provider.isReceiverPlaying
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        private func seekReceiver(to position: TimeInterval) {
            let clamped = min(max(position, 0), clock.duration > 0 ? clock.duration : position)
            provider?.seek(to: clamped)
            clock.current = clamped
        }

        // MARK: - Building Blocks

        /// Mirrors the engine overlays' control shape so the cast state reads
        /// as the same player, just pointed at another screen.
        private func circleGlyph(_ systemName: String, size: CGFloat, diameter: CGFloat) -> some View {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .glassEffectCompat(.regularInteractive, in: Circle())
        }

        private func timeString(from time: TimeInterval) -> String {
            guard time.isFinite, time >= 0 else { return "0:00" }
            let totalSeconds = Int(time)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                return String(format: "%d:%02d", minutes, seconds)
            }
        }
    }
#endif
