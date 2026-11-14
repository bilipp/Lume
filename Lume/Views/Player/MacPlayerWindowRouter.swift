//
//  MacPlayerWindowRouter.swift
//  Lume
//
//  Keeps macOS to ONE player, and owns the window it plays in.
//
//  `WindowGroup(id: "player", for: PlayableMedia.self)` keys a window on the
//  value it was opened with, so once the viewer steps to the next episode or
//  the next channel from inside the player, the open window no longer matches
//  the item the library shows as playing. Opening that item again would spawn
//  a second window — a second engine, a second audio session and a second Now
//  Playing publisher contending for the shared `MPRemoteCommandCenter`. So a
//  play request while a player is up raises that player and hands the stream
//  it actually wants to it through `pendingMedia`.
//
//  The player is either a window of its own or, when the viewer chose that in
//  Settings, an overlay on the library window it was started from. Either way
//  the router holds the `NSWindow`, so close, full screen and the window
//  buttons act on the player's window and never on whichever is frontmost.
//

import SwiftUI

#if os(macOS)
    import AppKit

    @Observable
    final class MacPlayerWindowRouter {
        static let shared = MacPlayerWindowRouter()

        /// The value the player was created with. `nil` while there is no
        /// player, which is the only case that may open one.
        private var launchMedia: PlayableMedia?

        /// What the player is playing right now, so a request for the stream
        /// already on screen only raises the window.
        private var activeMediaID: String?

        /// A stream an outside call site asked the open player to switch to.
        /// The player consumes it and clears it.
        var pendingMedia: PlayableMedia?

        /// The stream the player in a library window was started with, and the
        /// window showing it. Both `nil` while the player has its own window.
        private(set) var inlineMedia: PlayableMedia?
        private(set) var inlineHostID: UUID?

        /// Whether the player's window is in full screen, or on its way there.
        /// The top bar reads it: there are no window buttons to clear then.
        private(set) var isFullScreen = false

        /// The window the player is in: its own, or the library window hosting
        /// it. `NSApp.keyWindow` is the library window whenever the player is
        /// not frontmost, which is exactly when acting on it would close,
        /// retitle or resize the wrong one.
        @ObservationIgnored private weak var window: NSWindow?

        /// The library windows a player can be shown in.
        @ObservationIgnored private var hosts: [UUID: WeakWindow] = [:]

        /// Whether the host window was in full screen before the player went
        /// up in it. A full screen the viewer entered for the video ends with
        /// the video; one the library was already in stays.
        @ObservationIgnored private var hostWasFullScreen = false

        /// Whether the host window's toolbar was taken down for the player,
        /// and so has to come back with the library.
        @ObservationIgnored private var hidHostToolbar = false

        /// Closes the player's own window before it has been adopted.
        @ObservationIgnored private var dismissOwnWindow: (() -> Void)?

        @ObservationIgnored private var fullScreenObservers: [NSObjectProtocol] = []
        @ObservationIgnored private var closeAfterFullScreenExit: NSObjectProtocol?

        private struct WeakWindow {
            weak var window: NSWindow?
        }

        private init() {}

        // MARK: - Playing

        /// Whether the player is shown in a library window rather than its own.
        var isInline: Bool {
            inlineMedia != nil
        }

        /// Room the player's top bar leaves for the window buttons, which sit
        /// over its leading corner in a window and are gone in full screen.
        var windowButtonsInset: CGFloat {
            isFullScreen ? 0 : 56
        }

        /// Play `media`, creating a player only if there is none.
        func play(_ media: PlayableMedia, using openWindow: OpenWindowAction) {
            if let launchMedia {
                if media.id != activeMediaID { pendingMedia = media }
                raisePlayer(launchMedia: launchMedia, using: openWindow)
                return
            }
            // Claimed here rather than when the player appears, so a second
            // request in the same moment retargets this player instead of
            // opening another.
            launchMedia = media
            activeMediaID = media.id
            if MacPlayerPresentation.current == .currentWindow, let host = inlineHost() {
                hostWasFullScreen = host.window.styleMask.contains(.fullScreen)
                inlineHostID = host.id
                inlineMedia = media
            } else {
                openWindow(id: "player", value: media)
            }
        }

        private func raisePlayer(launchMedia: PlayableMedia, using openWindow: OpenWindowAction) {
            guard let window else {
                // Not adopted yet. Re-opening on the launch value focuses the
                // window that is on its way up rather than adding a second.
                if !isInline { openWindow(id: "player", value: launchMedia) }
                return
            }
            // `openWindow` leaves a minimised window in the Dock.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }

        /// The library window to show the player in: the one the viewer is in,
        /// else any. `nil` when none can take it, and the player gets its own
        /// window. A window with a sheet up can't: the sheet (Recordings, a
        /// source picker) would stay on top of the video.
        private func inlineHost() -> (id: UUID, window: NSWindow)? {
            hosts = hosts.filter { $0.value.window != nil }
            let candidates = hosts.compactMap { id, box in box.window.map { (id: id, window: $0) } }
            let usable = candidates.filter { $0.window.attachedSheet == nil && !$0.window.isMiniaturized }
            return usable.first { $0.window.isKeyWindow }
                ?? usable.first { $0.window.isMainWindow }
                ?? usable.first
        }

        // MARK: - Library windows

        func registerHost(_ id: UUID, window: NSWindow) {
            hosts[id] = WeakWindow(window: window)
        }

        func unregisterHost(_ id: UUID) {
            hosts[id] = nil
        }

        // MARK: - Player lifecycle

        func playerDidOpen(with media: PlayableMedia, dismissOwnWindow: @escaping () -> Void) {
            // A window macOS restored at launch arrives here without `play`.
            if launchMedia == nil {
                launchMedia = media
                activeMediaID = media.id
            }
            self.dismissOwnWindow = dismissOwnWindow
        }

        func playerDidClose() {
            // The library window outlives the player it hosted.
            setWindowButtonsVisible(true)
            if hidHostToolbar {
                window?.toolbar?.isVisible = true
                hidHostToolbar = false
            }
            stopObservingFullScreen()
            launchMedia = nil
            activeMediaID = nil
            pendingMedia = nil
            inlineMedia = nil
            inlineHostID = nil
            dismissOwnWindow = nil
            window = nil
            isFullScreen = false
        }

        func noteActiveMedia(_ media: PlayableMedia) {
            activeMediaID = media.id
            // Only ever the player's own window: a library window keeps its
            // title, and until a window has positively identified itself this
            // is a no-op rather than retitling whatever happened to be frontmost.
            if !isInline { window?.title = media.title }
        }

        func adopt(_ window: NSWindow, title: String, isRestorable: Bool) {
            guard self.window !== window else { return }
            self.window = window
            observeFullScreen(of: window)
            guard !isInline else {
                // The tab bar and the library's toolbar items would otherwise
                // sit on top of the video. Hidden on the window rather than
                // with `toolbarVisibility`, which takes the window buttons
                // down with the toolbar.
                if window.toolbar?.isVisible == true {
                    window.toolbar?.isVisible = false
                    hidHostToolbar = true
                }
                return
            }
            window.title = title
            // The window's launch value is what state restoration writes to
            // disk, and an expiring URL must not be restored; the per-device
            // resume point is all a recording persists.
            if !isRestorable { window.isRestorable = false }
        }

        // MARK: - Window actions

        /// Leave the player. Full screen is left first, and the window closed
        /// only once that transition has finished: closing a window in the
        /// middle of it strands an empty full-screen Space.
        func closePlayer() {
            if isInline {
                if let window, window.styleMask.contains(.fullScreen), !hostWasFullScreen {
                    window.toggleFullScreen(nil)
                }
                inlineMedia = nil
                inlineHostID = nil
                return
            }
            guard let window else {
                dismissOwnWindow?()
                return
            }
            guard window.styleMask.contains(.fullScreen) else {
                window.close()
                return
            }
            guard closeAfterFullScreenExit == nil else { return }
            closeAfterFullScreenExit = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let observer = self?.closeAfterFullScreenExit {
                        NotificationCenter.default.removeObserver(observer)
                        self?.closeAfterFullScreenExit = nil
                    }
                    window?.close()
                }
            }
            window.toggleFullScreen(nil)
        }

        /// Toggle full screen on the player's window. False when there is none.
        @discardableResult
        func toggleFullScreen() -> Bool {
            guard let window else { return false }
            window.toggleFullScreen(nil)
            return true
        }

        /// The close, minimise and zoom buttons come and go with the player's
        /// controls. Left up, they are the one thing that never leaves a video.
        func setWindowButtonsVisible(_ visible: Bool) {
            guard let window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = !visible
            }
        }

        // MARK: - Full screen tracking

        private func observeFullScreen(of window: NSWindow) {
            stopObservingFullScreen()
            isFullScreen = window.styleMask.contains(.fullScreen)
            let center = NotificationCenter.default
            // `will` for both, so the top bar moves with the transition
            // instead of jumping once it has landed.
            let changes: [(Notification.Name, Bool)] = [
                (NSWindow.willEnterFullScreenNotification, true),
                (NSWindow.didEnterFullScreenNotification, true),
                (NSWindow.willExitFullScreenNotification, false),
                (NSWindow.didExitFullScreenNotification, false)
            ]
            fullScreenObservers = changes.map { name, fullScreen in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isFullScreen = fullScreen }
                }
            }
        }

        private func stopObservingFullScreen() {
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
            fullScreenObservers = []
            if let closeAfterFullScreenExit {
                NotificationCenter.default.removeObserver(closeAfterFullScreenExit)
                self.closeAfterFullScreenExit = nil
            }
        }
    }

    /// Reports the window a view is mounted in.
    ///
    /// The player used to find its window by asking for `NSApp.keyWindow` a beat
    /// after appearing. That is a guess: the viewer may have clicked back to the
    /// library in the meantime, and it resolved to whichever window was frontmost
    /// — which then had its title rewritten on every in-player swap. A view can
    /// only ever be in one window, so it asks its own.
    struct MacWindowAccessor: NSViewRepresentable {
        let onResolve: (NSWindow) -> Void

        func makeNSView(context _: Context) -> NSView {
            let view = WindowReportingView()
            view.onResolve = onResolve
            return view
        }

        func updateNSView(_ view: NSView, context _: Context) {
            (view as? WindowReportingView)?.onResolve = onResolve
        }

        private final class WindowReportingView: NSView {
            var onResolve: ((NSWindow) -> Void)?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                // Out of the view update that put the view in the window.
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let window, self?.window === window else { return }
                    self?.onResolve?(window)
                }
            }
        }
    }

    extension View {
        /// Bind the player to the single macOS player: adopt its window on
        /// appear, release it on close, keep the window's title on the stream
        /// actually playing, and swap to a stream a library call site asked for.
        func macPlayerWindow(
            activeMedia: PlayableMedia,
            launchMedia: PlayableMedia,
            onRetarget: @escaping (PlayableMedia) -> Void
        ) -> some View {
            modifier(
                MacPlayerWindowModifier(
                    activeMedia: activeMedia, launchMedia: launchMedia, onRetarget: onRetarget
                )
            )
        }

        /// Lets this library window show the player, for viewers who chose to
        /// play in the current window. Applied inside the browse root's
        /// environment so the player inherits it, as a cover would.
        func macInlinePlayerHost() -> some View {
            modifier(MacInlinePlayerHost())
        }

        /// Moves a player's top bar clear of the window buttons.
        func macWindowButtonsInset() -> some View {
            padding(.leading, MacPlayerWindowRouter.shared.windowButtonsInset)
        }

        /// Shows the window buttons while the player's controls are up.
        func macWindowButtonsFollow(_ isControlsVisible: Bool) -> some View {
            onChange(of: isControlsVisible, initial: true) { _, visible in
                MacPlayerWindowRouter.shared.setWindowButtonsVisible(visible)
            }
            .onDisappear { MacPlayerWindowRouter.shared.setWindowButtonsVisible(true) }
        }
    }

    private struct MacPlayerWindowModifier: ViewModifier {
        let activeMedia: PlayableMedia
        let launchMedia: PlayableMedia
        let onRetarget: (PlayableMedia) -> Void

        @State private var router = MacPlayerWindowRouter.shared
        @Environment(\.dismissWindow) private var dismissWindow

        func body(content: Content) -> some View {
            content
                .background(MacWindowAccessor { window in
                    // The player opens as a window, the way a Mac app should —
                    // going full screen is the viewer's call — and SwiftUI's
                    // frame autosave brings it back at the size and position
                    // it was last left at.
                    router.adopt(window, title: activeMedia.title, isRestorable: !launchMedia.hasEphemeralURL)
                })
                .onAppear {
                    router.playerDidOpen(with: launchMedia) { dismissWindow(id: "player") }
                }
                .onDisappear { router.playerDidClose() }
                .onChange(of: activeMedia) { _, media in router.noteActiveMedia(media) }
                .onChange(of: router.pendingMedia, initial: true) { _, media in
                    guard let media else { return }
                    router.pendingMedia = nil
                    onRetarget(media)
                }
        }
    }

    private struct MacInlinePlayerHost: ViewModifier {
        @State private var hostID = UUID()
        @State private var router = MacPlayerWindowRouter.shared

        private var media: PlayableMedia? {
            router.inlineHostID == hostID ? router.inlineMedia : nil
        }

        func body(content: Content) -> some View {
            content
                .background(MacWindowAccessor { router.registerHost(hostID, window: $0) })
                .onDisappear { router.unregisterHost(hostID) }
                .overlay {
                    if let media {
                        FullScreenPlayerView(media: media)
                    }
                }
        }
    }

    /// Where a stream opens on macOS.
    nonisolated enum MacPlayerPresentation: String, CaseIterable, Identifiable {
        /// A player window of its own, beside the library.
        case newWindow
        /// Over the library window it was started from.
        case currentWindow

        static let `default` = MacPlayerPresentation.newWindow

        var id: String {
            rawValue
        }

        static func resolve(_ raw: String?) -> MacPlayerPresentation {
            raw.flatMap(MacPlayerPresentation.init(rawValue:)) ?? .default
        }

        static var current: MacPlayerPresentation {
            resolve(UserDefaults.standard.string(forKey: PlayerSettings.macPlayerPresentationKey))
        }
    }

#else

    extension View {
        /// No-op off macOS, where the player is presented in-place rather than
        /// in a window of its own.
        func macPlayerWindow(
            activeMedia _: PlayableMedia,
            launchMedia _: PlayableMedia,
            onRetarget _: @escaping (PlayableMedia) -> Void
        ) -> some View {
            self
        }

        /// No-op off macOS: there are no window buttons to clear.
        func macWindowButtonsInset() -> some View {
            self
        }
    }

#endif
