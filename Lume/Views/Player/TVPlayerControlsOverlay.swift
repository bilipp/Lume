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
        @Binding var currentTime: TimeInterval
        @Binding var duration: TimeInterval
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

        enum TabKind: Hashable { case episodes, info }
        @State var openTab: TabKind?
        @FocusState var focus: TVPlayerFocus?

        // MARK: - Body

        var body: some View {
            ZStack(alignment: .bottom) {
                scrim

                VStack(alignment: .leading, spacing: 26) {
                    upperRegion
                    controlRow
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 56)
            }
            .defaultFocus($focus, .transport)
            .onMoveCommand { direction in
                // With the controls up, up/down still surf channels — but only
                // for live TV and while no panel owns vertical navigation.
                guard media.isLive, openTab == nil,
                      direction == .up || direction == .down else { return }
                onSwitchChannel(direction)
            }
            .onChange(of: panelCloseToken) { closePanel() }
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

                scrubber
            }
        }

        // MARK: - Scrubber

        @ViewBuilder
        private var scrubber: some View {
            if showsScrubber {
                VStack(spacing: 6) {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .tint(.white)

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
            isSeries ? [.episodes, .info] : [.info]
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

#endif
