import AVFoundation
import SwiftData
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Top-level full-screen video host. Picks the engine implementation based on
/// the user setting, owns progress state, and persists watch progress back
/// into SwiftData for VOD content.
struct FullScreenPlayerView: View {
    let media: PlayableMedia

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
        @Environment(\.dismissWindow) private var dismissWindow
    #endif
    @AppStorage(PlayerSettings.engineKey) private var engineRaw: String = PlayerEngineKind.defaultValue.rawValue

    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var lastSaved: Date = .distantPast

    /// The stream currently playing. Starts as `media` but can be swapped when
    /// the viewer picks another episode from the in-player episode rail (tvOS).
    @State private var activeMedia: PlayableMedia

    init(media: PlayableMedia) {
        self.media = media
        _activeMedia = State(initialValue: media)
    }

    private var engine: PlayerEngineKind {
        PlayerEngineKind(rawValue: engineRaw) ?? .defaultValue
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            playerView
                .ignoresSafeArea()

            // VLCKit and KSPlayer ship their own close button inside the
            // auto-hiding controls overlay — showing a second one here means
            // the user sees duplicate X buttons whenever the controls are
            // visible. Only render our custom close for engines that don't
            // draw their own controls.
            if !engine.rendersOwnControls {
                closeButton
                    .padding(.top, 4)
                    .padding(.leading, 4)
            }
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onChange(of: currentTime) { _, _ in
            persistProgress(force: false)
        }
        .task {
            // Seed the recall pair with the channel we opened on, so the very
            // first in-player recall has somewhere to jump back to.
            LiveChannelHistory.record(activeMedia)
            configureAudioSessionForPlayback()
            #if os(macOS)
                enterMacFullScreen()
            #endif
        }
        .onDisappear {
            persistProgress(force: true)
            releaseAudioSession()
        }
    }

    @ViewBuilder
    private var playerView: some View {
        switch engine {
        case .avPlayer:
            AVPlayerEngineView(media: activeMedia, currentTime: $currentTime, duration: $duration)
        case .ksPlayer:
            KSPlayerEngineView(
                media: activeMedia,
                currentTime: $currentTime,
                duration: $duration,
                onSelectMedia: switchMedia
            )
        case .vlcKit:
            VLCPlayerEngineView(
                media: activeMedia,
                currentTime: $currentTime,
                duration: $duration,
                onSelectMedia: switchMedia
            )
        }
    }

    /// Persist the outgoing stream's progress, then swap in a new one. The
    /// engine reconfigures its player when `activeMedia` changes.
    private func switchMedia(to newMedia: PlayableMedia) {
        guard newMedia.id != activeMedia.id else { return }
        persistProgress(force: true)
        currentTime = 0
        duration = 0
        lastSaved = .distantPast
        activeMedia = newMedia
        // Slide the outgoing channel into the recall slot so `right` can jump back.
        LiveChannelHistory.record(newMedia)
    }

    private var closeButton: some View {
        Button {
            persistProgress(force: true)
            closePlayer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Close player")
        #if !os(tvOS)
            .keyboardShortcut(.escape, modifiers: [])
        #endif
    }

    private func closePlayer() {
        #if os(macOS)
            // Exit fullscreen first so the window animation is graceful, then close.
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            dismissWindow(id: "player")
        #else
            dismiss()
        #endif
    }

    private func configureAudioSessionForPlayback() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true, options: [])
        #endif
    }

    private func releaseAudioSession() {
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(macOS)
        private func enterMacFullScreen() {
            // Wait for the window to mount before toggling fullscreen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let window = NSApp.keyWindow ?? NSApp.windows.last(where: { $0.isVisible }) else { return }
                window.title = activeMedia.title
                if !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
    #endif

    private func persistProgress(force: Bool) {
        guard !activeMedia.isLive else {
            if force { touchLiveLastWatched() }
            return
        }
        guard currentTime > 0 else { return }
        if !force, Date().timeIntervalSince(lastSaved) < 5 { return }
        lastSaved = Date()

        let now = currentTime
        let total = duration
        let completed = total > 0 && now / total >= 0.9

        switch activeMedia.contentRef {
        case let .movie(id):
            updateMovie(id: id, progress: now, completed: completed)
        case let .episode(id):
            updateEpisode(id: id, progress: now, completed: completed)
        case .live:
            break
        }
    }

    private func updateMovie(id: String, progress: TimeInterval, completed: Bool) {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try? modelContext.fetch(descriptor).first else { return }
        movie.watchProgress = progress
        movie.lastWatchedDate = Date()
        if completed, !movie.isWatched {
            movie.isWatched = true
            TraktService.shared.syncWatched(movie: movie, watched: true)
        }
        try? modelContext.save()
    }

    private func updateEpisode(id: String, progress: TimeInterval, completed: Bool) {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let episode = try? modelContext.fetch(descriptor).first else { return }
        episode.watchProgress = progress
        episode.lastWatchedDate = Date()
        if completed, !episode.isWatched {
            episode.isWatched = true
            TraktService.shared.syncWatched(episode: episode, watched: true)
        }
        if let series = episode.series {
            series.lastWatchedDate = Date()
        }
        try? modelContext.save()
    }

    private func touchLiveLastWatched() {
        guard case let .live(id) = activeMedia.contentRef else { return }
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let stream = try? modelContext.fetch(descriptor).first else { return }
        stream.lastWatchedDate = Date()
        try? modelContext.save()
    }
}

#Preview {
    FullScreenPlayerView(media: PlayableMedia(
        id: "preview",
        url: URL(string: "https://example.com/stream.m3u8")!,
        title: "Sample Stream",
        subtitle: nil,
        posterURL: nil,
        kind: .live,
        startTime: 0,
        contentRef: .live("preview")
    ))
    .preferredColorScheme(.dark)
}
