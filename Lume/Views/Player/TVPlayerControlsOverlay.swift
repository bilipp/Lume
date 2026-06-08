//
//  TVPlayerControlsOverlay.swift
//  Lume
//
//  The tvOS player overlay. A complete rework that follows the Apple TV "Touch"
//  player template: a bottom scrim carrying a left caption + large title, a
//  right-aligned technical caption, a full-width progress bar with elapsed /
//  remaining times, and a control row of tab pills (left), transport buttons
//  (centre) and audio / subtitle menus (right).
//
//  The first tab ("Episodes", series only) raises a horizontal episode rail; the
//  second ("Info", the only tab for movies and live) raises an information
//  panel. See `TVPlayerPanels`.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI
    import VLCKitSPM

    struct TVPlayerControlsOverlay<Engine: TVPlaybackEngine>: View {
        @ObservedObject var coordinator: Engine
        let media: PlayableMedia
        /// High-frequency playback clock, held as the `@Observable` object. The
        /// overlay body never reads `current`/`duration` (only the scrubber leaf
        /// does), so playback ticks don't re-render the overlay — which is what
        /// made the audio/subtitle `Menu`s flicker on tvOS.
        let clock: PlaybackClock
        /// Bumped by the host (Menu/back press) to request closing an open panel.
        var panelCloseToken: Int
        var onTogglePlay: () -> Void
        var onResetHideTimer: () -> Void
        var onSelectMedia: (PlayableMedia) -> Void
        var onPanelOpenChange: (Bool) -> Void
        /// Surf to the next (`.up`) or previous (`.down`) live channel. Wired to
        /// the host so channel switching works identically whether the controls
        /// are showing or hidden.
        var onSwitchChannel: (MoveCommandDirection) -> Void

        /// `internal` (not `private`) so the derived-data extension in
        /// `TVPlayerControlsOverlay+Data.swift` can read this view's state.
        @Environment(\.modelContext) var modelContext

        // Resolved SwiftData backing for the active stream.
        @State var episode: Episode?
        @State var seasonEpisodes: [Episode] = []
        @State var movie: Movie?
        @State var liveStream: LiveStream?
        @State var epgNow: EPGListing?
        @State var epgNext: EPGListing?
        @State var seriesPlaylist: Playlist?
        @State var recentChannels: [LiveStream] = []
        @State var recentNowTitles: [String: String] = [:]

        // Scrubbing (VOD only). The progress bar is focusable; selecting it
        // pauses playback and enters a scrub mode where left/right step the
        // playhead. A second select commits the seek (and resumes playback if
        // it had been playing); the Menu button cancels without seeking.
        @State var isScrubbing = false
        @State var scrubTarget: TimeInterval = 0
        @State var wasPlayingBeforeScrub = false
        /// Grows on sustained same-direction input so a held d-pad covers
        /// ground quickly while a single tap still nudges precisely.
        @State var scrubStepLevel = 0
        @State var scrubLastDirection: MoveCommandDirection?
        /// Decays `scrubStepLevel` back to zero after a pause in input.
        @State var scrubResetTask: Task<Void, Never>?

        enum TabKind: Hashable { case episodes, recent, info }
        @State var openTab: TabKind?
        @FocusState var focus: TVPlayerFocus?

        // MARK: - Body

        var body: some View {
            ZStack(alignment: .bottom) {
                scrim

                VStack(alignment: .leading, spacing: 26) {
                    upperRegion
                    // While scrubbing, the transport / tab / menu controls are
                    // locked out so focus stays pinned on the bar and left/right
                    // step the playhead instead of moving focus.
                    controlRow
                        .disabled(isScrubbing)
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 56)
            }
            .defaultFocus($focus, .transport)
            .onMoveCommand { direction in
                // While scrubbing, left/right step the playhead; vertical moves
                // are swallowed so focus can't escape the bar.
                if isScrubbing {
                    if direction == .left || direction == .right { moveScrub(direction) }
                    return
                }
                // With the controls up, up/down still surf channels — but only
                // for live TV and while no panel owns vertical navigation.
                guard media.isLive, openTab == nil,
                      direction == .up || direction == .down else { return }
                onSwitchChannel(direction)
            }
            // The host bumps `panelCloseToken` on a Menu/back press. Mid-scrub
            // that cancels the scrub; otherwise it closes an open panel.
            .onChange(of: panelCloseToken) {
                if isScrubbing { cancelScrub() } else { closePanel() }
            }
            .task(id: media.id) { resolveContent() }
            .onAppear {
                // Every time the controls reappear this is a fresh subtree;
                // `defaultFocus` alone is unreliable here, so place focus on the
                // play/pause button explicitly once the buttons have mounted.
                Task { @MainActor in focus = .transport }
            }
            .onChange(of: focus) {
                // Moving between controls counts as activity — keep them up.
                onResetHideTimer()
            }
        }

        private var scrim: some View {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.55), location: 0.72),
                    .init(color: .black.opacity(0.9), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        // MARK: - Upper region (title block or active panel)

        @ViewBuilder
        private var upperRegion: some View {
            switch openTab {
            case .episodes:
                TVPlayerEpisodesPanel(
                    episodes: seasonEpisodes,
                    currentEpisodeID: episode?.id,
                    focus: $focus,
                    onSelect: select(episode:),
                    onClose: closePanel
                )
                .transition(.opacity)
            case .recent:
                TVPlayerRecentChannelsPanel(
                    channels: recentChannels,
                    currentChannelID: liveStream?.id,
                    nowTitles: recentNowTitles,
                    focus: $focus,
                    onSelect: select(channel:),
                    onClose: closePanel
                )
                .transition(.opacity)
            case .info:
                infoPanel
                    .transition(.opacity)
            case nil:
                titleBlock
                    .transition(.opacity)
            }
        }

        private var titleBlock: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let topCaption, !topCaption.isEmpty {
                            Text(topCaption)
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .frame(maxWidth: 900, alignment: .leading)
                        }
                        Text(media.title)
                            .font(.system(size: 56, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(radius: 8)
                    }

                    Spacer(minLength: 40)

                    if !techCaption.isEmpty {
                        Text(techCaption)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .frame(maxWidth: 800, alignment: .trailing)
                    }
                }

                // The scrubber lives in its own view so the high-frequency
                // playback clock (`currentTime`/`duration`) re-renders only it.
                // Reading those bindings here would re-evaluate the whole
                // overlay — including the audio/subtitle `Menu`s — on every tick,
                // which makes an open menu flicker heavily on tvOS. The bindings
                // are forwarded (projected), not read, so no dependency is added.
                TVPlayerScrubber(
                    isLive: media.isLive,
                    epgNow: epgNow,
                    clock: clock,
                    isScrubbing: isScrubbing,
                    scrubTarget: scrubTarget,
                    focus: $focus,
                    onToggleScrub: toggleScrub
                )
            }
        }

        // MARK: - Control row

        private var controlRow: some View {
            ZStack {
                transportControls

                HStack(spacing: 16) {
                    tabButtons
                    Spacer(minLength: 0)
                    trailingControls
                }
            }
            .focusSection()
        }

        // MARK: - Tabs

        var tabKinds: [TabKind] {
            if isSeries { return [.episodes, .info] }
            // The recents rail only earns a tab once there's somewhere to switch
            // to — i.e. a channel beyond the one playing now.
            if media.isLive, recentChannels.count > 1 { return [.recent, .info] }
            return [.info]
        }

        private var tabButtons: some View {
            HStack(spacing: 16) {
                ForEach(Array(tabKinds.enumerated()), id: \.offset) { index, kind in
                    Button(tabTitle(kind)) { toggle(tab: kind) }
                        .buttonStyle(TVChipButtonStyle(isSelected: openTab == kind))
                        .focused($focus, equals: .tab(index))
                }
            }
        }

        private func tabTitle(_ kind: TabKind) -> LocalizedStringKey {
            switch kind {
            case .episodes: "Episodes"
            case .recent: "Recent"
            case .info: "Info"
            }
        }

        // MARK: - Transport

        private var transportControls: some View {
            HStack(spacing: 26) {
                if !media.isLive {
                    leadingTransportButton
                    circleButton(systemImage: "gobackward.10", focus: .skipBackward) {
                        coordinator.skip(by: -10)
                        onResetHideTimer()
                    }
                }

                Button(action: onTogglePlay) {
                    Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(TVPlayerCircleButtonStyle(diameter: 78, glyphSize: 30))
                .focused($focus, equals: .transport)

                if !media.isLive {
                    circleButton(systemImage: "goforward.10", focus: .skipForward) {
                        coordinator.skip(by: 10)
                        onResetHideTimer()
                    }
                    trailingTransportButton
                }
            }
        }

        /// Leading outer button: previous episode for series, otherwise a longer
        /// rewind for movies.
        @ViewBuilder
        private var leadingTransportButton: some View {
            if isSeries {
                circleButton(systemImage: "backward.fill", focus: .previousItem, enabled: previousEpisode != nil) {
                    if let previousEpisode { select(episode: previousEpisode) }
                }
            } else {
                circleButton(systemImage: "backward.fill", focus: .previousItem) {
                    coordinator.skip(by: -300)
                    onResetHideTimer()
                }
            }
        }

        @ViewBuilder
        private var trailingTransportButton: some View {
            if isSeries {
                circleButton(systemImage: "forward.fill", focus: .nextItem, enabled: nextEpisode != nil) {
                    if let nextEpisode { select(episode: nextEpisode) }
                }
            } else {
                circleButton(systemImage: "forward.fill", focus: .nextItem) {
                    coordinator.skip(by: 300)
                    onResetHideTimer()
                }
            }
        }

        private func circleButton(
            systemImage: String,
            focus target: TVPlayerFocus,
            enabled: Bool = true,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: systemImage)
            }
            .buttonStyle(TVPlayerCircleButtonStyle())
            .focused($focus, equals: target)
            .disabled(!enabled)
        }

        // MARK: - Trailing controls (audio / subtitles)

        private var trailingControls: some View {
            HStack(spacing: 16) {
                audioTrackMenu
                subtitleMenu
            }
        }

        @ViewBuilder
        private var audioTrackMenu: some View {
            let tracks = coordinator.audioTrackOptions
            if tracks.count > 1 {
                Menu {
                    ForEach(tracks) { track in
                        Button {
                            coordinator.selectAudioTrack(id: track.id)
                            onResetHideTimer()
                        } label: {
                            if track.isSelected {
                                Label(track.label, systemImage: "checkmark")
                            } else {
                                Text(track.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "waveform")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused($focus, equals: .audio)
            }
        }

        @ViewBuilder
        private var subtitleMenu: some View {
            let tracks = coordinator.textTrackOptions
            if !tracks.isEmpty {
                Menu {
                    Button {
                        coordinator.selectTextTrack(id: nil)
                        onResetHideTimer()
                    } label: {
                        if !tracks.contains(where: \.isSelected) {
                            Label("Off", systemImage: "checkmark")
                        } else {
                            Text("Off")
                        }
                    }
                    ForEach(tracks) { track in
                        Button {
                            coordinator.selectTextTrack(id: track.id)
                            onResetHideTimer()
                        } label: {
                            if track.isSelected {
                                Label(track.label, systemImage: "checkmark")
                            } else {
                                Text(track.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused($focus, equals: .subtitles)
            }
        }

        // MARK: - Info panel

        private var infoPanel: some View {
            TVPlayerInfoPanel(
                title: infoTitle,
                subtitle: infoSubtitle,
                synopsis: infoSynopsis,
                metaLine: infoMetaLine,
                badges: infoBadges,
                posterURL: media.posterURL,
                primaryAction: infoPrimaryAction,
                secondaryAction: infoSecondaryAction,
                focus: $focus,
                onClose: closePanel
            )
        }
    }

    // MARK: - Scrubber

    /// The progress bar + elapsed / remaining time readout, isolated into its
    /// own view so the high-frequency playback clock invalidates only this
    /// leaf — not the whole overlay. See the call site in `titleBlock` for why
    /// (open-menu flicker on tvOS). Live progress is fixed to the EPG programme
    /// clock, so it stays a read-only bar; VOD gets the focusable, seekable
    /// scrubber.
    private struct TVPlayerScrubber: View {
        let isLive: Bool
        let epgNow: EPGListing?
        /// The high-frequency clock. Held as the `@Observable` object and read
        /// only here, so ticking it invalidates *only* this leaf view — not the
        /// overlay or the engine view above it (see the `@Binding`-to-observable
        /// re-render trap that drove the menu flicker).
        let clock: PlaybackClock
        let isScrubbing: Bool
        let scrubTarget: TimeInterval
        var focus: FocusState<TVPlayerFocus?>.Binding
        let onToggleScrub: () -> Void

        var body: some View {
            if showsScrubber {
                VStack(spacing: 6) {
                    progressBar

                    HStack {
                        Text(leadingTimeLabel)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(trailingTimeLabel)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText())
                }
            }
        }

        @ViewBuilder
        private var progressBar: some View {
            if isLive {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .tint(.white)
            } else {
                Button { onToggleScrub() } label: { Color.clear }
                    .buttonStyle(TVScrubBarStyle(fraction: scrubberFraction, isScrubbing: isScrubbing))
                    .focused(focus, equals: .scrubber)
            }
        }

        private var showsScrubber: Bool {
            isLive ? epgNow != nil : true
        }

        private var progressFraction: Double {
            if isLive, let epgNow {
                let total = epgNow.end.timeIntervalSince(epgNow.start)
                guard total > 0 else { return 0 }
                return min(max(Date().timeIntervalSince(epgNow.start) / total, 0), 1)
            }
            let total = max(clock.duration, 1)
            return min(max(clock.current / total, 0), 1)
        }

        /// VOD playhead position for the scrubber bar — the scrub target while
        /// scrubbing, otherwise live playback time.
        private var scrubberFraction: Double {
            let total = max(clock.duration, 1)
            let reference = isScrubbing ? scrubTarget : clock.current
            return min(max(reference / total, 0), 1)
        }

        private var leadingTimeLabel: String {
            if isLive, let epgNow { return Self.wallClock(epgNow.start) }
            return Self.timeString(isScrubbing ? scrubTarget : clock.current)
        }

        private var trailingTimeLabel: String {
            if isLive, let epgNow { return Self.wallClock(epgNow.end) }
            let reference = isScrubbing ? scrubTarget : clock.current
            return "-" + Self.timeString(max(clock.duration - reference, 0))
        }

        private static func wallClock(_ date: Date) -> String {
            date.formatted(date: .omitted, time: .shortened)
        }

        private static func timeString(_ time: TimeInterval) -> String {
            guard time.isFinite, time >= 0 else { return "0:00" }
            let total = Int(time)
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%d:%02d", minutes, seconds)
        }
    }

#endif
