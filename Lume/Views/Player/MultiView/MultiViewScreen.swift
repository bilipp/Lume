//
//  MultiViewScreen.swift
//  Lume
//
//  Multi-View: two to four live streams playing at once, one of them carrying
//  the audio. Useful for sports, and the only way to watch two channels from
//  providers that allow a single concurrent connection per playlist — hence the
//  picker being free to reach across playlists (#43).
//
//  Deliberately not `FullScreenPlayerView` repeated N times: that host owns
//  watch-progress writing, Next Up, skip-intro, AirPlay routing and the audio
//  session, all of which are single-stream concerns. A tile is video plus mute
//  (see `MultiViewTilePlayer`).
//

import AVFoundation
import SwiftUI

/// `UUID` is not `Identifiable`, so the sheet needs this to carry which tile the
/// channel picker is changing.
private struct MultiViewPickerTarget: Identifiable {
    let id: MultiViewSlot.ID
}

/// Presents the tile channel picker. A sheet on iOS/macOS; on tvOS its own
/// `fullScreenCover` stacked over Multi-View's, because a tvOS cover always
/// dismisses itself on Menu and nothing can stop it (neither `onExitCommand` nor
/// `interactiveDismissDisabled`). Nesting turns that into the behaviour we want:
/// Menu in the picker closes only the picker, Menu in the grid closes Multi-View.
/// Presenting it also takes focus off the grid, which tvOS would otherwise keep
/// reachable behind a plain overlay.
///
/// A `ViewModifier` rather than an inline `#if`: a conditional in the middle of a
/// modifier chain is something SwiftFormat cannot indent readably.
private struct MultiViewPickerPresentation: ViewModifier {
    @Binding var target: MultiViewPickerTarget?
    let usedMediaIDs: Set<String>
    let playlistsInUse: (MultiViewSlot.ID) -> Set<UUID>
    let onPick: (PlayableMedia, MultiViewSlot.ID) -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
            content.fullScreenCover(item: $target) { target in
                MultiViewChannelPickerTV(
                    usedMediaIDs: usedMediaIDs,
                    playlistsInUse: playlistsInUse(target.id),
                    onPick: { onPick($0, target.id) }
                )
            }
        #else
            content.sheet(item: $target) { target in
                MultiViewChannelPicker(
                    usedMediaIDs: usedMediaIDs,
                    playlistsInUse: playlistsInUse(target.id),
                    onPick: { onPick($0, target.id) }
                )
                #if os(macOS)
                // A macOS sheet is sized by its content, and a `List` has no
                // ideal height to offer — without a frame the picker opened as
                // a bare toolbar (title and search field) with the channel list
                // collapsed to nothing. Every other sheet here does the same.
                .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 600)
                #endif
            }
        #endif
    }
}

struct MultiViewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.dismissWindow) private var dismissWindow
    #endif

    @State var session: MultiViewSession
    /// The tile whose channel picker is open.
    @State private var pickingSlot: MultiViewPickerTarget?
    /// Which tile holds focus. Hoisted out of the tiles so the screen can hand
    /// focus to one on open — tvOS otherwise lands it on the close button, the
    /// first focusable in the tree.
    @FocusState private var focusedTile: MultiViewSlot.ID?
    #if os(tvOS)
        /// Set when the focus engine moves focus from one tile to another, and
        /// cleared by the move command that caused it — see `onMoveCommand` on
        /// the grid.
        @State private var engineMovedFocus = false
    #endif
    #if os(tvOS)
        /// Scope for `resetFocus`, which is how the chrome takes focus the moment
        /// it becomes visible: it is transparent until then, and a transparent
        /// view is not focusable, so it cannot simply be moved into.
        @Namespace var focusScope
        @Environment(\.resetFocus) private var resetFocus
    #endif
    #if os(tvOS)
        /// Drives the close button's own focus colours — never a size or a
        /// position, so the focus engine has no layout to fight with.
        @FocusState var isCloseFocused: Bool
        /// Same, for the layout pills.
        @FocusState var focusedLayout: MultiViewLayout?
    #endif

    /// Whether the floating chrome is showing. It starts hidden on tvOS (the grid
    /// is what you came for; a press up brings the controls in) and auto-hides
    /// elsewhere.
    @State var isChromeVisible = !isTV
    #if !os(tvOS)
        @State private var chromeHideTask: Task<Void, Never>?
    #endif

    /// The controls stay put while nothing is playing — there is nothing behind
    /// them to look at, and hiding them would strand the viewer: the only target
    /// left is an empty tile, and that opens the picker rather than bringing them
    /// back.
    var controlsArePinned: Bool {
        session.activeMedia.isEmpty
    }

    /// Whether the controls are on screen, pinned or not.
    var showsChrome: Bool {
        isChromeVisible || controlsArePinned
    }

    /// How far down the grid starts while the controls are showing, so they sit
    /// above the players instead of over them. Measured rather than hard-coded:
    /// the bar grows with Dynamic Type, and on tvOS it also sits inside the
    /// overscan margin.
    @State private var chromeInset: CGFloat = 0

    private static let chromeAutoHideDelay: TimeInterval = 4

    private static var isTV: Bool {
        #if os(tvOS)
            true
        #else
            false
        #endif
    }

    /// Dismisses the screen when it is hosted as an overlay (tvOS) rather than
    /// presented, where `dismiss` has nothing to act on.
    private let onClose: (() -> Void)?

    /// - Parameters:
    ///   - seed: channels to start with. Empty tiles prompt for a channel, so
    ///     opening Multi-View cold is a valid entry.
    ///   - onClose: supplied by an overlay host; omitted when presented.
    init(seed: [PlayableMedia] = [], onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        let stored = UserDefaults.standard.integer(forKey: MultiViewLayout.storageKey)
        let fitting = MultiViewLayout.fitting(seed.count)
        let layout = MultiViewLayout(rawValue: max(stored, fitting.rawValue)) ?? fitting
        _session = State(initialValue: MultiViewSession(seed: seed, layout: layout))
    }

    private var tileSpacing: CGFloat {
        #if os(tvOS)
            12
        #else
            6
        #endif
    }

    /// Outer margin around the grid. On tvOS the grid ignores the safe area, so
    /// this is the whole margin — just enough that a focused edge tile's lift
    /// isn't clipped.
    private var gridInset: CGFloat {
        #if os(tvOS)
            24
        #else
            6
        #endif
    }

    var body: some View {
        // The chrome floats *over* the grid rather than sitting in a VStack above
        // it: as a row it permanently took a band off the top, letterboxing every
        // tile. Overlaid, the tiles always have the whole screen, and the chrome
        // fades out entirely when it isn't wanted.
        ZStack(alignment: .top) {
            grid
            chrome
                .opacity(showsChrome ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showsChrome)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    #if os(tvOS)
                        // The grid ignores the safe area, so it starts at the top
                        // of the screen and has to clear the bar's position on
                        // screen — overscan margin included, not just its height.
                        chromeInset = frame.maxY
                    #else
                        chromeInset = frame.height
                    #endif
                }
        }
        #if os(tvOS)
        .focusScope(focusScope)
        #endif
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
            .statusBarHidden(true)
        #endif
            .persistentSystemOverlays(.hidden)
            .preferredColorScheme(.dark)
            .task {
                // The tiles' QoE reports would be nonsense against a summary that
                // models one stream at a time.
                PlaybackQoE.shared.isSuspended = true
                // Background indexing merges periodic saves into the main context,
                // which hitches every running decoder — more so with four of them.
                ContentIndexingService.shared.isPlaybackActive = true
                configureAudioSession()
                adoptQueuedChannels()
                landInitialFocus()
                scheduleChromeHide()
            }
            .onChange(of: session.layout) { _, layout in
                UserDefaults.standard.set(layout.rawValue, forKey: MultiViewLayout.storageKey)
            }
            .onChange(of: session.activeMedia.count) { _, count in
                // Removing the last stream has to bring the controls back, or
                // there is no way out of an empty grid.
                if count == 0 {
                    revealChrome()
                } else {
                    scheduleChromeHide()
                }
            }
        #if os(tvOS)
            // Focus back on a tile means the viewer is done with the controls.
            .onChange(of: focusedTile) { old, tile in
                // Tile-to-tile is the focus engine answering a move. A change
                // involving `nil` is the controls taking or releasing focus, and
                // must not be mistaken for navigation.
                if old != nil, tile != nil {
                    engineMovedFocus = true
                }
                if tile != nil {
                    isChromeVisible = false
                }
            }
        #endif
            .modifier(MultiViewPickerPresentation(
                target: $pickingSlot,
                usedMediaIDs: session.usedMediaIDs,
                playlistsInUse: { session.playlistsInUse(excluding: $0) },
                onPick: { media, slotID in
                    session.setMedia(media, in: slotID)
                    pickingSlot = nil
                }
            ))
        #if os(iOS) || os(tvOS)
            .onChange(of: scenePhase) { _, phase in
                // No engine plays Multi-View in the background, and four streams left
                // buffering behind the Home screen hold four decoders. `.inactive` is
                // a transient system overlay, so only a real move out acts.
                if phase == .background {
                    close()
                }
            }
        #endif
            .onDisappear {
                #if !os(tvOS)
                    chromeHideTask?.cancel()
                #endif
                releaseAudioSession()
                ContentIndexingService.shared.isPlaybackActive = false
                PlaybackQoE.shared.isSuspended = false
            }
        #if os(tvOS)
            // Only reached when the picker isn't presented — its own cover handles
            // Menu while it is up. With the controls showing, Menu puts them away
            // rather than tearing the whole grid down.
            .onExitCommand {
                // Pinned controls can't be dismissed, so Menu closes Multi-View
                // rather than doing nothing.
                if isChromeVisible, !controlsArePinned {
                    hideChrome()
                } else {
                    close()
                }
            }
        #endif
    }

    // MARK: - Grid

    private var grid: some View {
        // The arrangement depends on the container's aspect, not its size class:
        // an iPad in portrait and in landscape are both `.regular`, yet only one
        // of them can show two tiles side by side and keep them watchable.
        //
        // Every tile sits at the same place in the view tree whatever the
        // arrangement, and is placed by an explicit frame rather than by nested
        // stacks. Stacks would make a spotlight swap — or any layout change — a
        // structural move, and a tile that moves in the tree is a tile whose
        // player is torn down and whose stream reconnects. This way the tiles
        // only travel.
        GeometryReader { proxy in
            let frames = session.layout.frames(in: proxy.size, spacing: tileSpacing)
            ZStack {
                ForEach(Array(session.slots.enumerated()), id: \.element.id) { index, slot in
                    if frames.indices.contains(index) {
                        tile(slot: slot, at: index)
                            .frame(width: frames[index].width, height: frames[index].height)
                            .position(x: frames[index].midX, y: frames[index].midY)
                    }
                }
            }
            // Keyed on the slot order rather than on the slots themselves: a
            // channel arriving in a tile must not drag the whole grid through a
            // move animation, but a swap reorders them and should.
            .animation(.easeInOut(duration: 0.3), value: session.slots.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: session.layout)
        }
        .padding(gridInset)
        // Make room for the controls rather than sitting under them: the tiles
        // give up the band the bar occupies while it is showing, and take it back
        // as it goes away.
        .padding(.top, showsChrome ? chromeInset : 0)
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        #if os(tvOS)
            // Video belongs edge to edge; the safe area is for the controls,
            // which are a separate overlay. `gridInset` still leaves room for
            // the focus lift so a focused edge tile isn't clipped.
            .ignoresSafeArea()
            .focusSection()
            // A transparent view is not focusable on tvOS, so the hidden chrome
            // cannot be reached by moving up into it. Instead the up press the
            // focus engine has nowhere to send — the top tile row is the top of
            // the grid — is what brings the controls in.
            .onMoveCommand { direction in
                // Only when the press had nowhere to go — `onMoveCommand` fires for
                // every move, including ones the focus engine has already handled.
                //
                // Which of the two lands first is *not* stable, so both are checked
                // (measured on device): on an idle grid the focus change arrives
                // ~6ms before this handler, which then sees the destination tile —
                // `engineMovedFocus` is what catches it. Under live decoders the
                // order reverses and this handler runs ~6ms *before* the focus
                // change, still seeing the origin tile — `isFocusOnTopRow` is what
                // catches that. A time window can't tell them apart and was the
                // reason an up press from the bottom row still raised the controls.
                let engineHandledPress = engineMovedFocus
                engineMovedFocus = false
                // In the reversed order the focus change is still to come; clear the
                // flag it is about to set, or it would swallow the *next* press.
                Task { @MainActor in engineMovedFocus = false }
                guard direction == .up, !showsChrome, !engineHandledPress, isFocusOnTopRow else { return }
                isChromeVisible = true
                // Deferred: the reset has to land after the chrome has faded in
                // far enough to be focusable, and outside the focus engine's
                // animated context. Releasing the tile first matters — two
                // `@FocusState`s both asserting a value leaves the engine on the
                // incumbent. Should the engine decline the hand-off anyway, the
                // chrome is opaque by now, so a second press up reaches it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    focusedTile = nil
                    resetFocus(in: focusScope)
                }
            }
        #else
                // Taps in the gaps around the tiles bring the chrome back too, so
                // revealing it never has to change which tile is audible.
            .background(
                    Color.black
                        .contentShape(Rectangle())
                        .onTapGesture { revealChrome() }
                )
        #endif
    }

    private func tile(slot: MultiViewSlot, at index: Int) -> some View {
        MultiViewTile(
            slot: slot,
            hasAudio: session.isAudioSlot(slot.id),
            focusedTile: $focusedTile,
            showsControls: showsChrome,
            onPromote: isPromotable(index) ? {
                session.promote(slot.id)
                revealChrome()
            } : nil,
            onFocusAudio: {
                session.focusAudio(on: slot.id)
                revealChrome()
            },
            onPickChannel: {
                pickingSlot = MultiViewPickerTarget(id: slot.id)
                // So the controls are up when the picker is dismissed, rather
                // than the viewer landing back on a bare grid.
                revealChrome()
            },
            onRemove: { session.setMedia(nil, in: slot.id) }
        )
    }

    /// Whether selecting the tile at `index` should swap it onto the stage: only
    /// in the spotlight layout, only off the stage, and only once it has a
    /// channel — an empty tile's tap belongs to the channel picker.
    private func isPromotable(_ index: Int) -> Bool {
        guard session.hasSpotlight, session.slots.indices.contains(index) else { return false }
        let slot = session.slots[index]
        return !session.isStageSlot(slot.id) && slot.media != nil
    }

    /// Picks up channels queued for the Multi-View window. macOS only: every
    /// other platform builds the screen around its launch, so the seed is already
    /// in the session by the time this runs. Free tiles are filled in order, so
    /// starting a channel into a window that is already playing adds to the grid
    /// rather than replacing it.
    private func adoptQueuedChannels() {
        #if os(macOS)
            let queued = MultiViewLaunchQueue.shared.take()
            guard !queued.isEmpty else { return }
            var remaining = queued[...]
            for slot in session.slots where slot.media == nil {
                guard let next = remaining.popFirst() else { break }
                session.setMedia(next, in: slot.id)
            }
        #endif
    }

    // MARK: - Focus and chrome

    /// Hands focus to the first tile once the grid has mounted. Deferred a tick:
    /// the focus engine picks its own target as the tree appears (the close
    /// button, being first), and a write made in the same turn is overwritten.
    private func landInitialFocus() {
        guard let first = session.slots.first?.id else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            focusedTile = first
        }
    }

    /// Show the chrome and restart its hide timer. A no-op on tvOS, where the up
    /// press reveals it and moving focus back to a tile hides it again.
    private func revealChrome() {
        #if !os(tvOS)
            isChromeVisible = true
            scheduleChromeHide()
        #endif
    }

    #if os(tvOS)
        /// Whether the focused tile has nothing above it. A tvOS display is never
        /// portrait, so the grid is always in its landscape arrangement.
        private var isFocusOnTopRow: Bool {
            guard let focusedTile,
                  let index = session.slots.firstIndex(where: { $0.id == focusedTile })
            else { return false }
            return session.layout.isInTopRow(index, isPortrait: false)
        }

        /// Put the controls away and hand focus back to a tile, so the grid is
        /// navigable again rather than leaving focus stranded on hidden buttons.
        private func hideChrome() {
            isChromeVisible = false
            guard let first = session.slots.first?.id else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                focusedTile = first
            }
        }
    #endif

    private func scheduleChromeHide() {
        #if !os(tvOS)
            chromeHideTask?.cancel()
            // An empty grid has nothing to tap to bring the controls back — the
            // only tap target is an empty tile, and that opens the picker. Leave
            // them up until something is actually playing.
            guard !session.activeMedia.isEmpty else { return }
            chromeHideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.chromeAutoHideDelay))
                guard !Task.isCancelled else { return }
                isChromeVisible = false
            }
        #endif
    }

    // MARK: - Lifecycle

    func close() {
        if let onClose {
            onClose()
            return
        }
        #if os(macOS)
            dismissWindow(id: "multiview")
        #else
            dismiss()
        #endif
    }

    /// Plain `.playback` / `.moviePlayback`, without the full-screen player's
    /// request for the route's full channel width: only one tile is audible, and
    /// asking for an HDMI surround layout for a muted 2×2 grid would negotiate a
    /// wider route than anything here can fill.
    private func configureAudioSession() {
        PlaybackAudioRoute.activateStereo()
    }

    private func releaseAudioSession() {
        PlaybackAudioRoute.release()
    }
}
