#if os(macOS)
    import AppKit
    import SwiftUI

    /// Experimental Mac-only adapter. Every seek opens a local playlist at a
    /// retained segment boundary; capture continues through decoder replacement.
    @Observable
    final class TimeshiftPlayback {
        var url: URL?
        var revision = 0
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var origin: TimeInterval = 0
        var seekOffset: TimeInterval = 0
        var expired = false
        var interrupted = false
        var available = false
        private(set) var stopped = false
        private var running = false
        private var entries: [TimeshiftWindow.Entry] = []
        private var baseURL: URL?
        private var cache: TimeshiftCache?
        private var server: TimeshiftServer?
        private var capture: Task<Void, Never>?
        private var measuredBitrate: Double = 0

        func run(media: PlayableMedia) async {
            guard !running else { return }
            running = true
            stopped = false
            url = nil
            interrupted = false
            expired = false
            defer { stop(); running = false }
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumeTimeshift-\(UUID().uuidString)", isDirectory: true)
                let duration = TimeshiftPreferences.minutes() * 60
                // Duration is the user-facing limit. The larger safety cap and
                // free-space reserve still bound unexpectedly high bitrate input.
                let cache = try TimeshiftCache(directory: directory, durationLimit: Double(duration), byteLimit: 30_000_000_000)
                self.cache = cache
                let server = try TimeshiftServer(cache: cache)
                self.server = server
                baseURL = try await server.start()
                try Task.checkCancellation()
                capture = Task {
                    do {
                        try await cache.ingest(url: media.url, headers: media.httpHeaders ?? [:])
                    } catch {
                        if !Task.isCancelled { interrupted = true }
                    }
                }
                let warmingStarted = ContinuousClock.now
                while !Task.isCancelled, !stopped {
                    let snapshot = await cache.snapshot()
                    start = snapshot.start
                    end = snapshot.end
                    entries = snapshot.entries
                    if snapshot.end - snapshot.start >= 10 {
                        let bitrate = Double(snapshot.bytes) * 8 / (snapshot.end - snapshot.start)
                        measuredBitrate = bitrate
                    }
                    if url == nil, !entries.isEmpty, snapshot.end - snapshot.start >= 4 {
                        seek(to: max(start, end - 4))
                        available = true
                    }
                    if url == nil, warmingStarted.duration(to: .now) > .seconds(25) { interrupted = true }
                    if interrupted, url == nil {
                        capture?.cancel()
                        server.stop()
                        try? await cache.close()
                        break
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch { interrupted = true }
        }

        func seek(to position: TimeInterval) {
            guard let baseURL, let target = TimeshiftSeekTarget(position: position, entries: entries) else { return }
            origin = target.origin
            seekOffset = target.offset
            url = baseURL.appendingPathComponent("\(target.sequence)/index.m3u8")
            revision += 1
        }

        func position(_ clock: PlaybackClock) -> TimeInterval {
            max(start, min(end, origin + (clock.current.isFinite ? clock.current : 0)))
        }

        func skip(_ seconds: TimeInterval, clock: PlaybackClock) {
            seek(to: position(clock) + seconds)
        }

        func jumpToLive() {
            seek(to: max(start, end - 4))
        }

        func resumeIfExpired(clock: PlaybackClock) -> Bool {
            guard origin + clock.current < start else { return false }
            expired = true
            seek(to: start)
            return true
        }

        func stop() {
            stopped = true
            if measuredBitrate > 0 {
                UserDefaults.standard.set(measuredBitrate, forKey: TimeshiftPreferences.measuredBitrateKey)
                measuredBitrate = 0
            }
            available = false
            capture?.cancel()
            server?.stop()
            if let cache {
                Task { try? await cache.close() }
            }
            capture = nil
            server = nil
            cache = nil
        }
    }

    struct TimeshiftPlayerHost<Content: View>: View {
        let media: PlayableMedia
        let clock: PlaybackClock
        @ViewBuilder let content: (PlayableMedia) -> Content
        @State private var playback = TimeshiftPlayback()
        @State private var playerWindow: NSWindow?

        var body: some View {
            Group {
                if let url = playback.url {
                    content(media.replacingStream(url: url, httpHeaders: nil, startTime: playback.seekOffset))
                        .id(playback.revision)
                        .environment(playback)
                } else if playback.interrupted {
                    // Unsupported HLS is detected before the decoder opens. Stop
                    // capture first, then use the original, unmodified live path.
                    content(media)
                } else {
                    PlayerLoadingIndicator(title: media.title)
                }
            }
            .background(PlayerWindowAccessor { playerWindow = $0 })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let window = notification.object as? NSWindow, window === playerWindow else { return }
                playback.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard playback.stopped, let window = notification.object as? NSWindow, window === playerWindow else { return }
                Task { await playback.run(media: media) }
            }
            .task(id: media.url) { await playback.run(media: media) }
            .onChange(of: playback.revision) { _, _ in clock.reset() }
            .onDisappear { playback.stop() }
        }
    }
#endif
