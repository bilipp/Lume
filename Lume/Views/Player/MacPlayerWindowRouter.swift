//
//  MacPlayerWindowRouter.swift
//  Lume
//
//  Keeps macOS to ONE player window.
//
//  `WindowGroup(id: "player", for: PlayableMedia.self)` keys a window on the
//  value it was opened with, so once the viewer steps to the next episode or
//  the next channel from inside the player, the open window no longer matches
//  the item the library shows as playing. Opening that item again would spawn
//  a second window — a second engine, a second audio session and a second Now
//  Playing publisher contending for the shared `MPRemoteCommandCenter`. So
//  every play request re-opens on the window's *launch* value, which focuses
//  the window that already exists, and hands the stream it actually wants to
//  the running player through `pendingMedia`.
//

import SwiftUI

#if os(macOS)
    import AppKit

    @Observable
    final class MacPlayerWindowRouter {
        static let shared = MacPlayerWindowRouter()

        /// The value the open player window was created with. `nil` while no
        /// player window exists, which is the only case that may open one.
        private var launchMedia: PlayableMedia?

        /// What the open window is playing right now, so a request for the
        /// stream already on screen only raises the window.
        private var activeMediaID: String?

        /// A stream an outside call site asked the open window to switch to.
        /// The player consumes it and clears it.
        var pendingMedia: PlayableMedia?

        /// The player's own window, so the title can follow an in-player swap.
        /// `NSApp.keyWindow` is the library window whenever the player is not
        /// frontmost, which is exactly when a retitle would rename the wrong one.
        private weak var window: NSWindow?

        private init() {}

        /// Play `media` in the player window, creating it only if there is none.
        func play(_ media: PlayableMedia, using openWindow: OpenWindowAction) {
            guard let launchMedia else {
                openWindow(id: "player", value: media)
                return
            }
            if media.id != activeMediaID { pendingMedia = media }
            openWindow(id: "player", value: launchMedia)
        }

        func playerDidOpen(with media: PlayableMedia) {
            launchMedia = media
            activeMediaID = media.id
        }

        func playerDidClose() {
            launchMedia = nil
            activeMediaID = nil
            pendingMedia = nil
            window = nil
        }

        func noteActiveMedia(_ media: PlayableMedia) {
            activeMediaID = media.id
            // Only ever the player's own window: until one has positively
            // identified itself this is a no-op, rather than retitling
            // whatever window happened to be frontmost.
            window?.title = media.title
        }

        func adopt(_ window: NSWindow, title: String) {
            self.window = window
            window.title = title
        }
    }

    /// Reports the window the player's own view tree is mounted in.
    ///
    /// The player used to find its window by asking for `NSApp.keyWindow` a beat
    /// after appearing. That is a guess: the viewer may have clicked back to the
    /// library in the meantime, and it resolved to whichever window was frontmost
    /// — which then had its title rewritten on every in-player swap. A view can
    /// only ever be in one window, so it asks its own.
    struct PlayerWindowAccessor: NSViewRepresentable {
        let onResolve: (NSWindow) -> Void

        func makeNSView(context _: Context) -> NSView {
            let view = NSView(frame: .zero)
            // `window` is nil until the view joins the hierarchy, so resolve on
            // the next turn of the run loop rather than after a fixed delay.
            DispatchQueue.main.async { [weak view] in
                guard let window = view?.window else { return }
                onResolve(window)
            }
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }

    extension View {
        /// Bind the player to the single macOS player window: adopt it on
        /// appear, release it on close, keep its title on the stream actually
        /// playing, and swap to a stream a library call site asked for.
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
    }

    private struct MacPlayerWindowModifier: ViewModifier {
        let activeMedia: PlayableMedia
        let launchMedia: PlayableMedia
        let onRetarget: (PlayableMedia) -> Void

        @State private var router = MacPlayerWindowRouter.shared

        func body(content: Content) -> some View {
            content
                .background(PlayerWindowAccessor { window in
                    // Adopt this player's own window, then take it full screen.
                    router.adopt(window, title: activeMedia.title)
                    if !window.styleMask.contains(.fullScreen) {
                        window.toggleFullScreen(nil)
                    }
                })
                .onAppear { router.playerDidOpen(with: launchMedia) }
                .onDisappear { router.playerDidClose() }
                .onChange(of: activeMedia) { _, media in router.noteActiveMedia(media) }
                .onChange(of: router.pendingMedia) { _, media in
                    guard let media else { return }
                    router.pendingMedia = nil
                    onRetarget(media)
                }
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
    }

#endif
