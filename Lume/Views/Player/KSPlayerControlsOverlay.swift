import KSPlayer
import SwiftData
import SwiftUI

// MARK: - Controls Overlay (iOS / macOS)

// Native iOS-style controls for the KSPlayer engine on iOS / macOS, matching
// the VLCKit overlay: a center transport cluster (skip · large play/pause ·
// skip) in Liquid Glass, a title block paired with a grouped glass pill of
// track controls (subtitles · speed · aspect), and a clean full-width
// scrubber. tvOS uses the shared `TVPlayerControlsOverlay` instead (see
// `KSPlayerEngineView.tvBody`).
#if !os(tvOS)
    @available(iOS 16.0, macOS 13.0, *)
    struct KSPlayerControlsOverlay: View {
        @ObservedObject var coordinator: KSVideoPlayer.Coordinator
        let media: PlayableMedia
        @Binding var isPlaying: Bool
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        @Binding var currentTime: TimeInterval
        @Binding var duration: TimeInterval
        @Binding var isPipActive: Bool
        @Binding var hideTask: Task<Void, Never>?
        var onClose: () -> Void
        var onTogglePlay: () -> Void
        var onResetHideTimer: () -> Void
        var onScheduleHide: () -> Void

        @Environment(\.modelContext) private var modelContext
        /// Mirrors the backing model's favorite flag; refreshed when the media
        /// changes and updated locally on toggle so the heart re-renders.
        @State private var isFavorite = false

        var body: some View {
            ZStack {
                scrim

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    centerTransport
                    Spacer(minLength: 0)
                    bottomControls
                }
            }
            .task(id: media.id) {
                isFavorite = PlayerFavorites.isFavorite(for: media.contentRef, in: modelContext)
            }
        }

        // MARK: - Scrim

        /// Subtle top/bottom darkening so the white glyphs and title stay
        /// legible over bright video. The glass controls carry their own
        /// legibility; this only protects the bare text.
        private var scrim: some View {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.55), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        // MARK: - Top Bar

        private var topBar: some View {
            HStack {
                Button(action: onClose) {
                    circleGlyph("xmark", size: 15, diameter: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close player")
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                pipButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }

        private var pipButton: some View {
            Button {
                coordinator.playerLayer?.isPipActive.toggle()
                onResetHideTimer()
            } label: {
                circleGlyph(isPipActive ? "pip.exit" : "pip.enter", size: 16, diameter: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPipActive ? "Exit Picture in Picture" : "Picture in Picture")
        }

        // MARK: - Center Transport

        private var centerTransport: some View {
            HStack(spacing: 32) {
                if !media.isLive {
                    Button {
                        coordinator.skip(interval: -15)
                        onResetHideTimer()
                    } label: {
                        circleGlyph("gobackward.15", size: 22, diameter: 60)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip back 15 seconds")
                }

                Button(action: onTogglePlay) {
                    circleGlyph(
                        isPlaying ? "pause.fill" : "play.fill",
                        size: 30,
                        diameter: 76
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                if !media.isLive {
                    Button {
                        coordinator.skip(interval: 15)
                        onResetHideTimer()
                    } label: {
                        circleGlyph("goforward.15", size: 22, diameter: 60)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward 15 seconds")
                }
            }
        }

        // MARK: - Bottom Controls

        private var bottomControls: some View {
            VStack(spacing: 14) {
                HStack(alignment: .bottom, spacing: 16) {
                    titleBlock
                    Spacer(minLength: 0)
                    secondaryControls
                }

                if media.isLive {
                    liveIndicator
                } else {
                    scrubber
                    timeLabels
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }

        private var titleBlock: some View {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle = media.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(media.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }

        private var liveIndicator: some View {
            HStack(spacing: 7) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }

        // MARK: - Secondary Controls (grouped glass pill)

        private var secondaryControls: some View {
            HStack(spacing: 4) {
                if !coordinator.subtitleModel.subtitleInfos.isEmpty { subtitleMenu }
                if !media.isLive { playbackRateMenu }
                contentModeButton
                favoriteButton
            }
            .padding(.horizontal, 4)
            .glassEffectCompat(.regularInteractive, in: Capsule())
        }

        private var favoriteButton: some View {
            Button {
                isFavorite = PlayerFavorites.toggle(for: media.contentRef, in: modelContext)
                onResetHideTimer()
            } label: {
                pillGlyph(isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "In Favorites" : "Favorite")
        }

        @ViewBuilder
        private var subtitleMenu: some View {
            let model = coordinator.subtitleModel
            let hasSelection = model.selectedSubtitleInfo != nil
            Menu {
                Button {
                    model.selectedSubtitleInfo = nil
                    onResetHideTimer()
                } label: {
                    checkmarkLabel("Off", checked: !hasSelection)
                }
                ForEach(model.subtitleInfos, id: \.subtitleID) { track in
                    Button {
                        model.selectedSubtitleInfo = track
                        onResetHideTimer()
                    } label: {
                        checkmarkLabel(track.name, checked: model.selectedSubtitleInfo?.subtitleID == track.subtitleID)
                    }
                }
            } label: {
                pillGlyph("captions.bubble.fill", dimmed: !hasSelection)
            }
            .menuIndicator(.hidden)
        }

        private var playbackRateMenu: some View {
            Menu {
                ForEach([0.5, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { rate in
                    Button {
                        coordinator.playbackRate = rate
                        onResetHideTimer()
                    } label: {
                        checkmarkLabel(rateString(rate), checked: abs(coordinator.playbackRate - rate) < 0.01)
                    }
                }
            } label: {
                Text(verbatim: rateString(coordinator.playbackRate))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
        }

        private var contentModeButton: some View {
            Button {
                coordinator.isScaleAspectFill.toggle()
                onResetHideTimer()
            } label: {
                pillGlyph(coordinator.isScaleAspectFill ? "rectangle.fill" : "rectangle.arrowtriangle.2.inward")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(coordinator.isScaleAspectFill ? "Fit video" : "Fill screen")
        }

        // MARK: - Scrubber

        private var scrubber: some View {
            Slider(
                value: Binding<TimeInterval>(
                    get: { isSeeking ? seekPosition : (currentTime.isFinite ? currentTime : 0) },
                    set: { seekPosition = $0 }
                ),
                in: 0 ... max(duration.isFinite ? duration : 1, 1),
                onEditingChanged: onSliderEditingChanged
            )
            .tint(.white)
        }

        private var timeLabels: some View {
            HStack {
                Text(timeString(from: isSeeking ? seekPosition : currentTime))
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Spacer()
                Text(timeString(from: max(duration, 0)))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.caption.monospacedDigit())
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }

        private func onSliderEditingChanged(editing: Bool) {
            isSeeking = editing
            if editing {
                hideTask?.cancel()
                coordinator.playerLayer?.pause()
            } else {
                coordinator.seek(time: seekPosition)
                currentTime = seekPosition
                if isPlaying {
                    coordinator.playerLayer?.play()
                }
                onScheduleHide()
            }
        }

        // MARK: - Building Blocks

        /// A white glyph centered in an interactive Liquid Glass circle — the
        /// shared shape for every standalone control (close, PiP, transport).
        private func circleGlyph(
            _ systemName: String,
            size: CGFloat,
            diameter: CGFloat,
            dimmed: Bool = false
        ) -> some View {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(dimmed ? .white.opacity(0.55) : .white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .glassEffectCompat(.regularInteractive, in: Circle())
        }

        /// A white glyph sized for the grouped track pill. Carries no glass of
        /// its own — the enclosing capsule is the single glass surface, so
        /// stacking per-icon glass (prohibited) is avoided.
        private func pillGlyph(_ systemName: String, dimmed: Bool = false) -> some View {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(dimmed ? .white.opacity(0.55) : .white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }

        /// Compact rate label, e.g. `1×`, `1.25×`. `%g` drops trailing zeros.
        private func rateString(_ rate: Float) -> String {
            String(format: "%g×", rate)
        }

        @ViewBuilder
        private func checkmarkLabel(_ title: String, checked: Bool) -> some View {
            if checked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
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
