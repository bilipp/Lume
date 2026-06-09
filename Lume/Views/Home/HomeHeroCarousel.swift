//
//  HomeHeroCarousel.swift
//  Lume
//
//  A Netflix / Apple TV-style hero carousel for the top of the home screen.
//  Features trending movies the user owns using wide TMDB backdrop artwork,
//  auto-advancing every few seconds while honouring manual swipes.
//
//  The artwork lives in a paging ScrollView (`scrollTargetBehavior(.paging)` +
//  `scrollPosition`) so it works on macOS too. The title / overview / buttons
//  are a FIXED overlay on top (not inside the scroll content) so the copy wraps
//  to the view width instead of the scroll view's unbounded-width proposal.
//

import SwiftUI

struct HomeHeroCarousel: View {
    let items: [HeroItem]
    let onPlayMovie: (Movie) -> Void

    #if os(tvOS)
        /// The Siri Remote drives the carousel through focus, not gestures. We
        /// track focus to page on left/right swipes and pause auto-advance while
        /// the user is parked on the hero.
        @FocusState private var heroFocused: Bool
    #endif

    @State private var currentID: String?
    @State private var isInteracting = false

    /// Which hero the overlay is showing. Deliberately LAGS the scroll position:
    /// on a page change the overlay fades out, swaps while invisible, then fades
    /// back in (see `crossfadeInfo()`) — a clean fade rather than a cross-dissolve.
    @State private var displayedID: String?
    @State private var infoOpacity: Double = 1

    private let autoAdvanceInterval: Duration = .seconds(6)
    /// Width below which the hero switches to the stacked, full-width layout.
    private let compactWidthThreshold: CGFloat = 600

    /// Sentinel scroll ids for the boundary clones, so `currentID` can tell a
    /// clone apart from the real page it mirrors (see `normaliseClonePosition()`).
    private static let headCloneID = "hero-clone-head"
    private static let tailCloneID = "hero-clone-tail"

    #if os(tvOS)
        private let heroHeight: CGFloat = 960
    #elseif os(macOS)
        private let heroHeight: CGFloat = 800
    #else
        private let heroHeight: CGFloat = 800
    #endif

    /// The rendered pages: the real items padded with a clone of the LAST item
    /// at the front and the FIRST at the back. Paging onto a clone is one slide;
    /// once settled there `normaliseClonePosition()` silently re-seats to the
    /// real page, so looping never scrolls back through every slide in between.
    private var slots: [HeroSlot] {
        guard items.count > 1, let first = items.first, let last = items.last else {
            return items.map { HeroSlot(id: $0.id, item: $0) }
        }
        return [HeroSlot(id: Self.headCloneID, item: last)]
            + items.map { HeroSlot(id: $0.id, item: $0) }
            + [HeroSlot(id: Self.tailCloneID, item: first)]
    }

    /// The real hero id the scroll rests on, resolving either clone to the item
    /// it mirrors. Everything user-facing keys off THIS (not `currentID`) so the
    /// silent clone→real re-seat is never seen as a page change.
    private var currentItemID: String? {
        guard let currentID else { return items.first?.id }
        return slots.first { $0.id == currentID }?.item.id ?? currentID
    }

    private var currentHero: HeroItem? {
        items.first { $0.id == currentItemID } ?? items.first
    }

    /// The hero whose copy is in the overlay. Lags `currentHero` so the outgoing
    /// title fades out before the next fades in; falls back before the first swap.
    private var displayedHero: HeroItem? {
        items.first { $0.id == displayedID } ?? currentHero
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let isCompact = width < compactWidthThreshold

            ZStack(alignment: .bottomLeading) {
                artwork
                // Darken the bottom so the title and buttons stay legible.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                if let hero = displayedHero {
                    #if os(tvOS)
                        // STABLE identity (no `.id(hero.id)`) so the focused hero
                        // survives paging. Left/right pages via `onMoveCommand`; we
                        // re-assert focus since the link identity changes movie⇄series.
                        HeroInfo(
                            hero: hero,
                            isCompact: isCompact,
                            onPlayMovie: onPlayMovie,
                            heroFocus: $heroFocused,
                            onPrevious: { retreat(); heroFocused = true },
                            onNext: { advance(); heroFocused = true }
                        )
                        .opacity(infoOpacity)
                    #else
                        // Fixed overlay — no `.id`/`.transition` so a stable view can
                        // fade out/in via `infoOpacity` rather than cross-dissolving.
                        HeroInfo(hero: hero, isCompact: isCompact, onPlayMovie: onPlayMovie)
                            .opacity(infoOpacity)
                    #endif
                }

                pageIndicator
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(width: width, height: heroHeight)
            .clipped()
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.35), value: currentItemID)
        }
        .frame(height: heroHeight)
        #if os(tvOS)
            // tvOS applies overscan safe-area insets (~60pt) on every edge
            .ignoresSafeArea(edges: .horizontal)
            // The hero is one full-width focusable surface (see `HeroInfo`), so the
            // tab bar's downward move lands on it and upward moves route back to it.
            .focusSection()
        #endif
            .onAppear {
                // Seed `displayedID` first so the initial assignment skips the crossfade.
                if displayedID == nil { displayedID = items.first?.id }
                if currentID == nil { currentID = items.first?.id }
                prefetchNeighbours()
            }
            .onChange(of: currentItemID) { _, _ in
                prefetchNeighbours()
                crossfadeInfo()
            }
            .task(id: items.count) {
                await autoAdvance()
            }
    }

    /// Warms the cache for the slides on either side so they appear instantly.
    private func prefetchNeighbours() {
        guard let currentItemID,
              let index = items.firstIndex(where: { $0.id == currentItemID })
        else { return }
        let count = items.count
        guard count > 1 else { return }
        // Wrap the neighbours so the loop targets (last⇄first) are warm too.
        let neighbours = [(index - 1 + count) % count, (index + 1) % count]
            .compactMap { items[$0].imageURL }
        guard !neighbours.isEmpty else { return }
        Task { await ImagePipeline.shared.prefetch(neighbours, maxPixelSize: nil) }
    }

    // MARK: - Scrolling artwork

    private var artwork: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(slots) { slot in
                        HeroBackdrop(url: slot.item.imageURL)
                            .frame(width: width, height: heroHeight)
                            .id(slot.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, newPhase, _ in
                // Only user-driven scrolling pauses auto-advance; `.animating` is
                // our own programmatic paging, which once latched this `true` forever.
                isInteracting = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                // Settled on a boundary clone? Silently re-seat to the real page.
                if newPhase == .idle { normaliseClonePosition() }
            }
        }
    }

    // MARK: - Page indicator

    @ViewBuilder
    private var pageIndicator: some View {
        if items.count > 1 {
            HStack(spacing: 8) {
                ForEach(items) { hero in
                    Circle()
                        .fill(hero.id == currentItemID ? Color.white : Color.white.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            #if os(tvOS)
                // Keep the indicator clear of the bottom overscan margin.
                .padding(.bottom, 40)
            #else
                .padding(.bottom, 14)
            #endif
                .animation(.easeInOut, value: currentItemID)
        }
    }

    // MARK: - Auto-advance

    private func autoAdvance() async {
        guard items.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: autoAdvanceInterval)
            if Task.isCancelled { return }
            // Don't yank the carousel out from under an active gesture.
            guard !isInteracting else { continue }
            #if os(tvOS)
                let wasFocused = heroFocused
                advance()
                if wasFocused { heroFocused = true }
            #else
                advance()
            #endif
        }
    }

    private func advance() {
        guard slots.count > 1 else { return }
        let index = slots.firstIndex { $0.id == currentID } ?? 1
        let next = slots[min(index + 1, slots.count - 1)].id
        withAnimation(.easeInOut(duration: 0.6)) { currentID = next }
    }

    private func retreat() {
        guard slots.count > 1 else { return }
        let index = slots.firstIndex { $0.id == currentID } ?? 1
        let previous = slots[max(index - 1, 0)].id
        withAnimation(.easeInOut(duration: 0.6)) { currentID = previous }
    }

    /// On settling on a boundary clone, jump WITHOUT animation to the real page
    /// it mirrors: the artwork is identical so it's invisible, but it restocks
    /// real pages on the far side so the next wrap is again a single slide.
    private func normaliseClonePosition() {
        guard let currentID else { return }
        if currentID == Self.headCloneID {
            self.currentID = items.last?.id
        } else if currentID == Self.tailCloneID {
            self.currentID = items.first?.id
        }
    }

    /// Fades the overlay out, swaps it while invisible, then fades back in. The
    /// fade-in is slightly longer so the new copy lands once the 0.6s artwork
    /// page settles. Reading `currentItemID` in the completion (not a captured
    /// value) self-heals rapid paging to whatever slide is current on reappear.
    private func crossfadeInfo() {
        guard displayedID != currentItemID else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            infoOpacity = 0
        } completion: {
            displayedID = currentItemID
            withAnimation(.easeOut(duration: 0.45)) {
                infoOpacity = 1
            }
        }
    }
}

/// One rendered page in the carousel. Real items use their own `HeroItem.id`;
/// boundary clones reuse a mirrored item but carry a sentinel id so the scroll
/// position can distinguish a clone from the page it duplicates.
private struct HeroSlot: Identifiable {
    let id: String
    let item: HeroItem
}

// MARK: - Preview

#Preview("Multiple Items") {
    let items = [
        HeroItem.movie(
            Movie(id: "preview-hero-1", streamId: 1, name: "The Matrix"),
            backdropURL: URL(string: "https://image.tmdb.org/t/p/w1280/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"),
            overview: "A computer hacker learns about the true nature of reality."
        ),
        HeroItem.series(
            Series(id: "preview-series-1", seriesId: 1, name: "Breaking Bad", num: 1),
            backdropURL: nil,
            overview: "A high school chemistry teacher diagnosed with inoperable cancer."
        ),
        HeroItem.movie(
            Movie(id: "preview-hero-2", streamId: 2, name: "Inception"),
            backdropURL: nil,
            overview: "A thief who steals corporate secrets through dream-sharing technology."
        )
    ]
    HomeHeroCarousel(items: items, onPlayMovie: { _ in })
}

#Preview("Single Item") {
    let items = [
        HeroItem.movie(
            Movie(id: "preview-hero-3", streamId: 3, name: "The Dark Knight"),
            backdropURL: nil,
            overview: "When the menace known as the Joker wreaks havoc on Gotham."
        )
    ]
    HomeHeroCarousel(items: items, onPlayMovie: { _ in })
}

#Preview("Empty") {
    HomeHeroCarousel(items: [], onPlayMovie: { _ in })
}

// MARK: - Backdrop image

private struct HeroBackdrop: View {
    let url: URL?

    var body: some View {
        GeometryReader { geo in
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .overlay { ProgressView() }
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .overlay {
                            Image(systemName: "film")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Title / overview / buttons

private struct HeroInfo: View {
    let hero: HeroItem
    let isCompact: Bool
    let onPlayMovie: (Movie) -> Void

    #if os(tvOS)
        // Parent focus binding for the hero surface, plus left/right paging callbacks.
        var heroFocus: FocusState<Bool>.Binding
        var onPrevious: () -> Void = {}
        var onNext: () -> Void = {}
    #endif

    var body: some View {
        #if os(tvOS)
            heroSurface
        #else
            infoStack
        #endif
    }

    /// The title / overview / action block — the focusable surface's label on
    /// tvOS, a fixed overlay elsewhere.
    private var infoStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleLogo(
                url: hero.logoURL,
                title: hero.title,
                maxWidth: isCompact ? 260 : 400,
                maxHeight: isCompact ? 64 : 110
            ) {
                Text(hero.title)
                    .font(isCompact ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                    .lineLimit(2)
                    .shadow(radius: 6)
            }

            if !hero.overview.isEmpty {
                Text(hero.overview)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
            }

            actionButtons
                .controlSize(.large)
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(.top, isCompact ? 16 : 24)
        #if os(tvOS)
            // Carousel bleeds to the edges on tvOS; pad into the title-safe area (~60pt).
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        #else
            .padding(.horizontal, isCompact ? 16 : 24)
            // Extra bottom inset so the (taller) stacked buttons clear the page
            // indicator instead of colliding with it / clipping at the edge.
            .padding(.bottom, 40)
        #endif
            // Cap the readable column on wide windows; fill when compact, pin leading.
            .frame(maxWidth: isCompact ? .infinity : 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(tvOS)
        /// On tvOS the ENTIRE hero is one focusable control: the tab bar's
        /// downward move is a geometric search, and a full-width surface can't be
        /// missed (a small leading button would be skipped for a card below it).
        /// Selecting opens Details; left/right pages the carousel.
        @ViewBuilder
        private var heroSurface: some View {
            if let movie = hero.movie {
                heroLink(value: movie)
            } else if let series = hero.series {
                heroLink(value: series)
            }
        }

        /// The hero as one full-WIDTH `NavigationLink` pinned to the bottom at its
        /// natural height — NOT full height, so the Focus Engine has room above it
        /// to move "up" into the tab bar. `HeroSurfaceButtonStyle` draws no focus
        /// highlight (it would wash the surface white); `detailsPill` carries it.
        private func heroLink(value: some Hashable) -> some View {
            NavigationLink(value: value) {
                infoStack
                    .contentShape(Rectangle())
            }
            .buttonStyle(HeroSurfaceButtonStyle())
            .focused(heroFocus)
            .onMoveCommand { direction in
                switch direction {
                case .left: onPrevious()
                case .right: onNext()
                default: break
                }
            }
        }
    #endif

    @ViewBuilder
    private var actionButtons: some View {
        #if os(tvOS)
            // Not a control: the whole hero is the focusable surface (see
            // `heroSurface`). This is just a Details affordance that reflects the
            // hero's focus state so it reads like a button when highlighted.
            detailsPill
        #else
            if isCompact {
                // Stacked, full-width buttons so nothing overflows horizontally.
                VStack(spacing: 12) {
                    playButton(fullWidth: true)
                    detailsButton(fullWidth: true)
                }
            } else {
                HStack(spacing: 12) {
                    playButton(fullWidth: false)
                    detailsButton(fullWidth: false)
                }
            }
        #endif
    }

    #if os(tvOS)
        /// A purely visual "Details" affordance. It isn't focusable itself — the
        /// enclosing hero surface is — so it mirrors the hero's focus state to
        /// flip between a glassy resting style and a solid highlighted style.
        private var detailsPill: some View {
            Label("Details", systemImage: "info.circle")
                .fontWeight(.semibold)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    heroFocus.wrappedValue
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
                .foregroundStyle(heroFocus.wrappedValue ? .black : .white)
                .scaleEffect(heroFocus.wrappedValue ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.18), value: heroFocus.wrappedValue)
        }
    #endif

    // The hero exposes separate Play and Details buttons on iOS / macOS. On
    // tvOS the whole hero is a single focusable surface, so these are unused.
    #if !os(tvOS)
        @ViewBuilder
        private func playButton(fullWidth: Bool) -> some View {
            if let movie = hero.movie {
                Button {
                    onPlayMovie(movie)
                } label: {
                    playLabel(fullWidth: fullWidth)
                }
                .modifier(HeroPlayButtonStyle())
            } else if let series = hero.series {
                NavigationLink(value: series) {
                    playLabel(fullWidth: fullWidth)
                }
                .modifier(HeroPlayButtonStyle())
            }
        }

        @ViewBuilder
        private func detailsButton(fullWidth: Bool) -> some View {
            if let movie = hero.movie {
                NavigationLink(value: movie) {
                    detailsLabel(fullWidth: fullWidth)
                }
                .modifier(HeroDetailsButtonStyle())
            } else if let series = hero.series {
                NavigationLink(value: series) {
                    detailsLabel(fullWidth: fullWidth)
                }
                .modifier(HeroDetailsButtonStyle())
            }
        }

        private func playLabel(fullWidth: Bool) -> some View {
            Label("Play", systemImage: "play.fill")
                .fontWeight(.semibold)
                .foregroundStyle(.black)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }

        private func detailsLabel(fullWidth: Bool) -> some View {
            Label("Details", systemImage: "info.circle")
                .fontWeight(.semibold)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
    #endif
}

// MARK: - Hero button styles

#if os(tvOS)
    /// A focus-neutral button style for the full-hero surface: it renders only
    /// the label, so tvOS adds no automatic focus highlight (which would wash
    /// the entire hero white). The `detailsPill` reflects focus instead.
    private struct HeroSurfaceButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
#endif

/// Matches the carousel Play button to the tvOS detail screen's glass pill,
/// while keeping the prominent white style on iOS / macOS.
private struct HeroPlayButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
            content.buttonStyle(TVGlassButtonStyle())
        #else
            content
                .buttonStyle(.borderedProminent)
                .tint(.white)
        #endif
    }
}

/// Matches the carousel Details button to the tvOS detail screen's glass pill,
/// while keeping the bordered style on iOS / macOS.
private struct HeroDetailsButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
            content.buttonStyle(TVGlassButtonStyle())
        #else
            content
                .buttonStyle(.bordered)
                .tint(.white)
        #endif
    }
}
