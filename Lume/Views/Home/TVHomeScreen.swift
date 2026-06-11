//
//  TVHomeScreen.swift
//  Lume
//
//  The immersive tvOS home screen, modelled on the Apple TV app and Apple's
//  "Creating a tvOS media catalog app in SwiftUI" sample:
//
//  • The TMDB backdrop is a FIXED full-screen layer behind the scroll view
//    (crossfading between slides), so artwork always fills the screen.
//  • The scroll content opens with a "showcase" slot sized to the screen height
//    minus `TVHomeMetrics.rowPeek`, so the first row teases at the bottom edge.
//  • `TVHomeFoldBehavior` (a custom `ScrollTargetBehavior`, in
//    `TVHomeFold.swift`) snaps the fold in three stages: the first move down
//    parks the first row mid-screen with the hero's bottom strip still visible
//    (`.strip`), the next hides the hero entirely (`.rows`), and moving back
//    up restores the full hero.
//

#if os(tvOS)

    import SwiftUI

    // MARK: - Hero model

    /// Carousel state for the immersive hero: the featured items, the current and
    /// displayed slide, and the auto-advance clock. An `@Observable` class so the
    /// 20 Hz `progress` ticks only re-render the views that actually read
    /// `progress` (the page dots) — never the showcase or the scroll content.
    @MainActor @Observable
    final class TVHeroModel {
        private(set) var items: [HeroItem] = []
        private(set) var currentIndex = 0

        /// Fill of the active page dot (0…1); doubles as the auto-advance clock
        /// so the loading-bar dot and the slide jump can never drift apart.
        private(set) var progress: Double = 0

        /// Which hero the info overlay is showing. Deliberately LAGS the current
        /// slide: on a page change the copy fades out, swaps while invisible,
        /// then fades back in (see `crossfadeInfo`).
        private var displayedID: String?
        private(set) var infoOpacity: Double = 1

        /// Set while the hero is below the fold so the carousel doesn't page
        /// (and prefetch artwork) where nobody can see it.
        var isPaused = false

        private let autoAdvanceInterval: Duration = .seconds(6)

        var currentHero: HeroItem? {
            items.indices.contains(currentIndex) ? items[currentIndex] : items.first
        }

        var displayedHero: HeroItem? {
            items.first { $0.id == displayedID } ?? currentHero
        }

        func configure(items: [HeroItem]) {
            self.items = items
            if !items.indices.contains(currentIndex) { currentIndex = 0 }
            if displayedID == nil || !items.contains(where: { $0.id == displayedID }) {
                displayedID = items.first?.id
            }
            prefetchNeighbours()
        }

        func advance() {
            page(by: 1)
        }

        func retreat() {
            page(by: -1)
        }

        /// One 50ms tick of the auto-advance clock. Returns `true` when the bar
        /// has filled and the caller should page (the view pages so it can also
        /// re-assert hero focus, which the model knows nothing about).
        func tickAutoAdvance() -> Bool {
            guard items.count > 1 else { return false }
            // While paused, hold the bar EMPTY rather than frozen so the slide
            // always gets a full dwell once it becomes visible again.
            if isPaused {
                progress = 0
                return false
            }
            if progress >= 1 {
                // Reset BEFORE paging so the next tick can't re-trigger an
                // advance while the page change is still settling.
                progress = 0
                return true
            }
            let total = Double(autoAdvanceInterval.components.seconds)
            progress = min(progress + 0.05 / total, 1)
            return false
        }

        private func page(by delta: Int) {
            guard items.count > 1 else { return }
            progress = 0
            // Animate the index change so the backdrop (keyed by hero id with an
            // opacity transition) crossfades rather than swapping hard.
            withAnimation(.easeInOut(duration: 0.8)) {
                currentIndex = (currentIndex + delta + items.count) % items.count
            }
            crossfadeInfo()
            prefetchNeighbours()
        }

        /// Fades the info overlay out, swaps it while invisible, then fades back
        /// in. Reading `currentHero` in the completion (not a captured value)
        /// self-heals rapid paging to whatever slide is current on reappear.
        private func crossfadeInfo() {
            guard displayedID != currentHero?.id else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                infoOpacity = 0
            } completion: {
                self.displayedID = self.currentHero?.id
                withAnimation(.easeOut(duration: 0.45)) {
                    self.infoOpacity = 1
                }
            }
        }

        /// Warms the cache for the slides on either side so crossfades land on an
        /// already-decoded image instead of a placeholder flash.
        private func prefetchNeighbours() {
            let count = items.count
            guard count > 1 else { return }
            let neighbours = [(currentIndex - 1 + count) % count, (currentIndex + 1) % count]
                .compactMap { items[$0].imageURL }
            guard !neighbours.isEmpty else { return }
            Task { await ImagePipeline.shared.prefetch(neighbours, maxPixelSize: nil) }
        }
    }

    // MARK: - Screen

    /// The immersive home: full-screen backdrop behind a single native vertical
    /// ScrollView. tvOS owns focus and scrolling; `TVHomeFoldBehavior` only
    /// adjusts where each focus-driven scroll comes to rest.
    struct TVHomeScreen<Rows: View>: View {
        let heroItems: [HeroItem]
        /// Called when the hero surface is selected; the owner navigates.
        let onSelectHero: (HeroItem) -> Void
        @ViewBuilder var rows: Rows

        @State private var model = TVHeroModel()
        @State private var zone: TVHomeZone = .expanded
        @State private var containerHeight: CGFloat = 0

        private var showcaseHeight: CGFloat {
            max(containerHeight - TVHomeMetrics.rowPeek, 0)
        }

        private var belowFold: Bool {
            zone != .expanded
        }

        private var hasHero: Bool {
            !heroItems.isEmpty
        }

        var body: some View {
            ZStack {
                if hasHero {
                    TVHeroBackdrop(model: model, belowFold: belowFold)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TVHomeMetrics.rowSpacing) {
                        if hasHero {
                            TVHeroShowcase(model: model, onSelect: onSelectHero)
                        }
                        rows
                    }
                    .padding(.top, hasHero ? 0 : 60)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .scrollTargetBehavior(TVHomeFoldBehavior(
                    zone: zone,
                    showcaseHeight: hasHero ? showcaseHeight : 0
                ))
                .onScrollGeometryChange(for: TVHomeZone.self) { geometry in
                    TVHomeZone(
                        offset: geometry.contentOffset.y + geometry.contentInsets.top,
                        showcaseHeight: hasHero ? showcaseHeight : 0
                    )
                } action: { _, newZone in
                    guard newZone != zone else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { zone = newZone }
                }
            }
            // Full-bleed vertically so the showcase spans the real screen height
            // and the first row peeks at the true bottom edge. Ignoring on the
            // CONTAINER (not the ScrollView) matters: a ScrollView keeps its
            // safe-area-reduced frame and quietly ignores this modifier. The
            // horizontal safe area stays so rows keep their overscan inset.
            .ignoresSafeArea(edges: .vertical)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                containerHeight = height
            }
            .onChange(of: zone) { _, newZone in
                model.isPaused = newZone != .expanded
            }
            .onChange(of: heroItems) { _, items in
                model.configure(items: items)
            }
            .onAppear { model.configure(items: heroItems) }
        }
    }

    // MARK: - Backdrop layer

    /// The fixed full-screen artwork behind the scroll content. Crossfades on
    /// page changes and frosts/dims once the user scrolls below the fold —
    /// Apple's material-masked-by-gradient treatment from the media catalog
    /// sample, plus a bottom scrim that keeps the hero copy legible.
    private struct TVHeroBackdrop: View {
        let model: TVHeroModel
        let belowFold: Bool

        var body: some View {
            ZStack {
                Color.black

                if let hero = model.currentHero {
                    CachedAsyncImage(url: hero.imageURL) { phase in
                        // The placeholder must be a REAL view: lifecycle
                        // modifiers (CachedAsyncImage's internal `.task`) never
                        // fire on EmptyView, so an empty `.empty` branch means
                        // the image load never starts.
                        if case let .success(image) = phase {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.black
                        }
                    }
                    // Keyed by slide so a page change swaps views, and the
                    // opacity transition (driven by the model's animated index
                    // change) reads as a crossfade.
                    .id(hero.id)
                    .transition(.opacity)
                }
            }
            .overlay {
                // Frosted glass that creeps up from the bottom: a light wash
                // behind the peeking row when expanded, the whole screen once
                // the user is below the fold.
                Rectangle()
                    .fill(.regularMaterial)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.2),
                                .init(color: .black.opacity(belowFold ? 1 : 0.3), location: 0.375),
                                .init(color: .black.opacity(belowFold ? 1 : 0), location: 0.5)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    }
            }
            .overlay {
                // Bottom scrim so the title and overview stay legible over
                // bright artwork.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.45), location: 0.62),
                        .init(color: .black.opacity(0.85), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay {
                // Extra dim below the fold so the rows read against a calm,
                // near-black background that still carries the artwork's tint.
                Color.black.opacity(belowFold ? 0.45 : 0)
            }
            .compositingGroup()
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Showcase

    /// The focusable hero surface at the top of the scroll content: title logo,
    /// overview, Details affordance and the slide dots, bottom-aligned inside a
    /// slot that fills the screen minus the first-row peek. Selecting reports
    /// the hero via `onSelect` (navigation happens in `HomeView`); left/right
    /// pages the carousel.
    private struct TVHeroShowcase: View {
        let model: TVHeroModel
        let onSelect: (HeroItem) -> Void

        @FocusState private var heroFocused: Bool

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                if let hero = model.displayedHero {
                    heroContent(for: hero)
                }
            }
            // Fill the slot so the natural-height link pins to its BOTTOM —
            // the space above is what lets "up" from the focused hero reach
            // the tab bar.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            // Size the slot BEFORE `.focusSection()`: a sizing wrapper outside
            // the focus section detaches it from the focus engine and the hero
            // silently stops being focusable (focus skips from the tab bar
            // straight to the first row).
            .containerRelativeFrame(.vertical, alignment: .topLeading) { length, _ in
                max(length - TVHomeMetrics.rowPeek, 0)
            }
            .focusSection()
            .task(id: model.items.map(\.id)) {
                await runAutoAdvance()
            }
        }

        /// The bottom info block (natural height, pinned to the slot's bottom
        /// by the enclosing ZStack) — NOT the whole slot. Filling the slot
        /// leaves no room above the focused hero, so "up" stops reaching the
        /// tab bar and the focus engine remaps it to other keys, breaking
        /// left/right carousel paging.
        ///
        /// Only the Details pill inside is focusable (see `info(for:)`): the
        /// block itself spans the full width, and a full-width focus target
        /// projects "down" from the SCREEN CENTER — landing on the third card
        /// of the first row instead of the first. A full-width focus-section
        /// band around the pill keeps it reachable from the tab bar above.
        private func heroContent(for hero: HeroItem) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                info(for: hero)
                    .opacity(model.infoOpacity)

                TVHeroPageDots(model: model)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// CONSTANT HEIGHT across slides: the logo slot is a fixed frame and the
        /// overview always reserves its three lines. The surface is a focused
        /// element — if its frame changed per slide, the focus engine would
        /// re-scroll to track it on every manual page and the rows below would
        /// visibly jump.
        private func info(for hero: HeroItem) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                TitleLogo(
                    url: hero.logoURL,
                    title: hero.title,
                    maxWidth: 500,
                    maxHeight: 130
                ) {
                    Text(hero.title)
                        .font(.system(size: 56, weight: .bold))
                        .lineLimit(2)
                        .shadow(radius: 6)
                }
                // Fresh identity per slide: two logos have different fitted
                // sizes, and a STABLE image view interpolates between them —
                // the logo visibly "grows" into place when an animation is in
                // flight (manual paging inherits one from the focus engine).
                // The swap happens while `infoOpacity` is 0, so replacing the
                // view outright is invisible.
                .id(hero.id)
                .frame(height: 130, alignment: .bottomLeading)

                Text(hero.overview)
                    .font(.callout)
                    .lineLimit(3, reservesSpace: true)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
                    .frame(maxWidth: 640, alignment: .leading)

                // One STRUCTURALLY STABLE Button for every slide — a plain
                // content swap on a stable view, so paging never drops focus.
                // (A `NavigationLink` whose branch flips movie⇄series gets a
                // NEW identity on those pages: focus falls to the first row,
                // tvOS scrolls down to reveal it and back up on re-assert, and
                // the whole home visibly jumps.) Navigation is reported via
                // `onSelect` instead.
                //
                // The pill is the ONLY focusable element of the showcase, so
                // the focus engine projects "down" from its narrow left-edge
                // frame and lands on the FIRST card of the row below.
                //
                // The enclosing FULL-WIDTH `.focusSection()` band is what
                // keeps the narrow pill reachable from above: the tab bar's
                // buttons sit near the screen's center, and a vertical focus
                // search only considers candidates that overlap the source
                // horizontally — without the band, "down" from the tab bar
                // skips the left-edge pill and lands mid-row. (The slot-level
                // section can't catch that move: it ENCLOSES the tab bar, so
                // it is never "below" it.) The band redirects to its only
                // focusable child without affecting the pill's own outgoing
                // projection.
                HStack {
                    Button {
                        onSelect(hero)
                    } label: {
                        detailsPill
                    }
                    .buttonStyle(TVHeroSurfaceButtonStyle())
                    .focused($heroFocused)
                    .onMoveCommand { direction in
                        // Defer the page OUT of the move-command handler: tvOS
                        // delivers it inside the focus engine's animated
                        // update, and every layout change made there is
                        // implicitly animated at the UIKit layer — the info
                        // block visibly floats into place and drags the first
                        // row along. (`Transaction.disablesAnimations` can't
                        // reach that layer; it was tried and failed.) One
                        // main-actor hop later the event context is gone,
                        // making manual paging take the exact same path as
                        // auto-advance, which pages from a plain task and has
                        // only the model's own crossfades.
                        switch direction {
                        case .left: Task { model.retreat() }
                        case .right: Task { model.advance() }
                        default: break
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                .padding(.top, 10)
            }
            .foregroundStyle(.white)
        }

        /// The label of the hero's Button. The focus-neutral button style adds
        /// no automatic highlight, so the pill mirrors `heroFocused` itself to
        /// flip between a glassy resting style and a solid highlighted style.
        private var detailsPill: some View {
            Label("Details", systemImage: "info.circle")
                .fontWeight(.semibold)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    heroFocused
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
                .foregroundStyle(heroFocused ? .black : .white)
                .scaleEffect(heroFocused ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.18), value: heroFocused)
        }

        /// Drives the model's auto-advance clock.
        private func runAutoAdvance() async {
            guard model.items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if model.tickAutoAdvance() {
                    model.advance()
                }
            }
        }
    }

    /// Renders only the page dots, so the model's 20 Hz `progress` ticks
    /// re-render this leaf and nothing else.
    private struct TVHeroPageDots: View {
        let model: TVHeroModel

        var body: some View {
            if model.items.count > 1 {
                HeroPageIndicator(
                    count: model.items.count,
                    activeIndex: model.currentIndex,
                    progress: model.progress
                )
            }
        }
    }

    /// A focus-neutral button style for the full-hero surface: it renders only
    /// the label, so tvOS adds no automatic focus highlight (which would wash
    /// the entire hero white). The `detailsPill` reflects focus instead.
    private struct TVHeroSurfaceButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }

    // MARK: - Preview

    #Preview("Immersive Home") {
        let items = [
            HeroItem.movie(
                Movie(id: "preview-hero-1", streamId: 1, name: "The Matrix"),
                backdropURL: URL(string: "https://image.tmdb.org/t/p/w1280/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"),
                overview: "A computer hacker learns about the true nature of reality."
            ),
            HeroItem.movie(
                Movie(id: "preview-hero-2", streamId: 2, name: "Inception"),
                backdropURL: nil,
                overview: "A thief who steals corporate secrets through dream-sharing technology."
            )
        ]
        NavigationStack {
            TVHomeScreen(
                heroItems: items,
                onSelectHero: { _ in },
                rows: {
                    Text("Rows go here")
                        .padding(.horizontal)
                }
            )
        }
    }

#endif
