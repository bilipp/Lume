import SwiftUI

#if canImport(VLCKitSPM)
    import VLCKitSPM

    /// Apple-style auto-hiding controls overlay for the VLCKit engine.
    ///
    /// Extracted from `VLCPlayerEngineView` to keep each type under the
    /// SwiftLint `type_body_length` threshold. Mirrors the design language of
    /// the KSPlayer overlay (top close bar, center play button, bottom
    /// scrubber + transport + secondary controls).
    struct VLCPlayerControlsOverlay: View {
        @ObservedObject var coordinator: VLCPlayerCoordinator
        let media: PlayableMedia
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        @Binding var currentTime: TimeInterval
        @Binding var duration: TimeInterval
        @Binding var hideTask: Task<Void, Never>?
        var onClose: () -> Void
        var onTogglePlay: () -> Void
        var onResetHideTimer: () -> Void
        var onScheduleHide: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                topBar
                Spacer()
                centerPlayButton
                Spacer()
                bottomBar
            }
            .background(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.2),
                        .init(color: .clear, location: 0.8),
                        .init(color: .black.opacity(0.35), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }

        // MARK: - Top Bar

        private var topBar: some View {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close player")
                #if !os(tvOS)
                    .keyboardShortcut(.escape, modifiers: [])
                #endif

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }

        // MARK: - Center Play Button

        @ViewBuilder
        private var centerPlayButton: some View {
            if !coordinator.isPlaying {
                Button(action: onTogglePlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }

        // MARK: - Bottom Bar

        private var bottomBar: some View {
            VStack(spacing: 10) {
                timeSliderView

                HStack(spacing: 0) {
                    timeLabels
                    Spacer()
                    transportControls
                    Spacer()
                    secondaryControls
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .padding(.top, 8)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0), location: 0),
                                .init(color: .black.opacity(1), location: 0.25),
                                .init(color: .black.opacity(1), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
        }

        // MARK: - Time Labels

        private var timeLabels: some View {
            HStack(spacing: 3) {
                Text(timeString(from: isSeeking ? seekPosition : currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                Text("/")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
                Text(timeString(from: max(duration, 0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }

        // MARK: - Time Slider

        private var timeSliderView: some View {
            #if os(tvOS)
                // `Slider` is unavailable on tvOS. Show a non-interactive
                // progress bar instead — seeking is driven by the focusable
                // skip buttons and the Siri remote.
                ProgressView(
                    value: min(currentTime.isFinite ? currentTime : 0, max(duration, 1)),
                    total: max(duration.isFinite ? duration : 1, 1)
                )
                .progressViewStyle(.linear)
                .tint(.white)
                .opacity(media.isLive ? 0 : 1)
            #else
                Slider(
                    value: Binding<TimeInterval>(
                        get: { isSeeking ? seekPosition : (currentTime.isFinite ? currentTime : 0) },
                        set: { seekPosition = $0 }
                    ),
                    in: 0 ... max(duration.isFinite ? duration : 1, 1),
                    onEditingChanged: { onSliderEditingChanged(editing: $0) }
                )
                .tint(.white)
                .disabled(media.isLive)
            #endif
        }

        private func onSliderEditingChanged(editing: Bool) {
            isSeeking = editing
            if editing {
                hideTask?.cancel()
            } else {
                coordinator.seek(to: seekPosition)
                currentTime = seekPosition
                onScheduleHide()
            }
        }

        // MARK: - Transport Controls

        private var transportControls: some View {
            HStack(spacing: 22) {
                skipButton(seconds: -15, symbol: "gobackward.15")

                Button(action: onTogglePlay) {
                    Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                skipButton(seconds: 15, symbol: "goforward.15")
            }
        }

        private func skipButton(seconds: Double, symbol: String) -> some View {
            Button {
                coordinator.skip(by: seconds)
                onResetHideTimer()
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(media.isLive)
        }

        // MARK: - Secondary Controls

        private var secondaryControls: some View {
            HStack(spacing: 12) {
                playbackRateMenu
                audioTrackMenu
                subtitleMenu
                pipButton
            }
        }

        @ViewBuilder
        private var pipButton: some View {
            #if os(iOS) || os(macOS)
                if coordinator.isPipSupported {
                    Button {
                        coordinator.togglePictureInPicture()
                        onResetHideTimer()
                    } label: {
                        Image(systemName: coordinator.isPipActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(coordinator.isPipActive ? "Exit Picture in Picture" : "Picture in Picture")
                }
            #endif
        }

        private var playbackRateMenu: some View {
            Menu {
                ForEach([0.5, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { rate in
                    Button {
                        coordinator.playbackRate = rate
                        onResetHideTimer()
                    } label: {
                        if abs(coordinator.playbackRate - rate) < 0.01 {
                            Label("\(rate, specifier: "%.2g")x", systemImage: "checkmark")
                        } else {
                            Text("\(rate, specifier: "%.2g")x")
                        }
                    }
                }
            } label: {
                Text("\(coordinator.playbackRate, specifier: "%.2g")x")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .menuIndicator(.hidden)
        }

        @ViewBuilder
        private var audioTrackMenu: some View {
            let tracks = coordinator.audioTracks
            if tracks.count > 1 {
                Menu {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                        Button {
                            coordinator.selectAudioTrack(track)
                            onResetHideTimer()
                        } label: {
                            if track.isSelectedExclusively {
                                Label(track.trackName, systemImage: "checkmark")
                            } else {
                                Text(track.trackName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .menuIndicator(.hidden)
            }
        }

        @ViewBuilder
        private var subtitleMenu: some View {
            let tracks = coordinator.textTracks
            if !tracks.isEmpty {
                Menu {
                    Button {
                        coordinator.selectTextTrack(nil)
                        onResetHideTimer()
                    } label: {
                        if !tracks.contains(where: \.isSelectedExclusively) {
                            Label("Off", systemImage: "checkmark")
                        } else {
                            Text("Off")
                        }
                    }
                    ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                        Button {
                            coordinator.selectTextTrack(track)
                            onResetHideTimer()
                        } label: {
                            if track.isSelectedExclusively {
                                Label(track.trackName, systemImage: "checkmark")
                            } else {
                                Text(track.trackName)
                            }
                        }
                    }
                } label: {
                    let hasSelection = tracks.contains(where: \.isSelectedExclusively)
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(hasSelection ? .white : .white.opacity(0.55))
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .menuIndicator(.hidden)
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
