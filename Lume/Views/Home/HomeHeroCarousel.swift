//
//  HomeHeroCarousel.swift
//  Lume
//
//  A Netflix / Apple TV-style hero carousel for the top of the home screen.
//  Features trending movies the user owns using wide TMDB backdrop artwork,
//  auto-advancing every few seconds while honouring manual swipes.
//
//  The artwork lives in a paging ScrollView (`scrollTargetBehavior(.paging)` +
//  `scrollPosition`) so it works on macOS too, where the page tab style is
//  unavailable. The title / overview / buttons are drawn as a FIXED overlay on
//  top of the carousel (not inside the scrolling content) and simply update to
//  the current page. Keeping the text out of the scroll axis avoids the
//  unbounded-width proposal a horizontal ScrollView hands its content, which
//  otherwise stops the copy from wrapping.
//

import SwiftUI

/// One featured item in the hero carousel: a Movie or Series the user owns,
/// plus the TMDB-sourced wide artwork and copy that make it look cinematic.
enum HeroItem: Identifiable, Hashable {
    case movie(Movie, backdropURL: URL?, overview: String)
    case series(Series, backdropURL: URL?, overview: String)

    var id: String {
        switch self {
        case let .movie(movie, _, _): "movie-\(movie.id)"
        case let .series(series, _, _): "series-\(series.id)"
        }
    }

    var title: String {
        switch self {
        case let .movie(movie, _, _): movie.name
        case let .series(series, _, _): series.name
        }
    }

    var overview: String {
        switch self {
        case let .movie(_, _, overview): overview
        case let .series(_, _, overview): overview
        }
    }

    var imageURL: URL? {
        switch self {
        case let .movie(movie, backdrop, _):
            backdrop ?? URL(string: movie.streamIcon ?? "")
        case let .series(series, backdrop, _):
            backdrop ?? URL(string: series.cover ?? "")
        }
    }

    /// The title's wordmark logo, shown in place of the text title when the
    /// title has been enriched from TMDB and a logo is available.
    var logoURL: URL? {
        switch self {
        case let .movie(movie, _, _): TMDBClient.logoURL(movie.logoPath)
        case let .series(series, _, _): TMDBClient.logoURL(series.logoPath)
        }
    }

    var movie: Movie? {
        if case let .movie(movie, _, _) = self { return movie }
        return nil
    }

    var series: Series? {
        if case let .series(series, _, _) = self { return series }
        return nil
    }
}

struct HomeHeroCarousel: View {
    let items: [HeroItem]
    let onPlayMovie: (Movie) -> Void

    #if os(tvOS)
        /// The Siri Remote drives the carousel through focus, not gestures. The
        /// whole hero is a single focusable control (see `HeroInfo`); we track
        /// whether it holds focus so we can page on left/right swipes and pause
        /// auto-advance while the user is parked on the hero.
        @FocusState private var heroFocused: Bool
    #endif

    @State private var currentID: String?
    @State private var isInteracting = false

    private let autoAdvanceInterval: Duration = .seconds(6)
    /// Width below which the hero switches to the stacked, full-width layout.
    private let compactWidthThreshold: CGFloat = 600

    #if os(tvOS)
        private let heroHeight: CGFloat = 960
    #elseif os(macOS)
        private let heroHeight: CGFloat = 800
    #else
        private let heroHeight: CGFloat = 800
    #endif

    private var currentHero: HeroItem? {
        items.first { $0.id == currentID } ?? items.first
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let isCompact = width < compactWidthThreshold

            ZStack(alignment: .bottomLeading) {
                artwork
                // Darken the bottom so the title and buttons stay legible over
                // any artwork.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                if let hero = currentHero {
                    #if os(tvOS)
                        // Keep a STABLE identity (no `.id(hero.id)`) so the focused
                        // hero survives paging instead of being torn down and losing
                        // focus. Left/right paging is wired through the hero's
                        // `onMoveCommand`; we re-assert focus after paging because the
                        // link's identity changes across movie⇄series.
                        HeroInfo(
                            hero: hero,
                            isCompact: isCompact,
                            onPlayMovie: onPlayMovie,
                            heroFocus: $heroFocused,
                            onPrevious: { retreat(); heroFocused = true },
                            onNext: { advance(); heroFocused = true }
                        )
                    #else
                        // Fixed overlay in normal layout — text wraps to `width`.
                        HeroInfo(hero: hero, isCompact: isCompact, onPlayMovie: onPlayMovie)
                            .id(hero.id)
                            .transition(.opacity)
                    #endif
                }

                pageIndicator
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(width: width, height: heroHeight)
            .clipped()
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.35), value: currentID)
        }
        .frame(height: heroHeight)
        #if os(tvOS)
            // tvOS applies overscan safe-area insets (~60pt) on every edge
            .ignoresSafeArea(edges: .horizontal)
            // Group the hero as a focus section. The hero is a single, full-width
            // focusable surface (see `HeroInfo`), so the tab bar's downward focus
            // move lands on it directly and an upward move from any card in the
            // row below routes back to it regardless of horizontal position.
            .focusSection()
        #endif
            .onAppear {
                if currentID == nil { currentID = items.first?.id }
                prefetchNeighbours()
            }
            .onChange(of: currentID) { _, _ in prefetchNeighbours() }
            .task(id: items.count) {
                await autoAdvance()
            }
    }

    /// Warms the cache for the slides on either side of the current one so they
    /// appear instantly when the carousel pages (full-resolution, tvOS 4K).
    private func prefetchNeighbours() {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else { return }
        let neighbours = [index - 1, index + 1]
            .filter { items.indices.contains($0) }
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
                    ForEach(items) { hero in
                        HeroBackdrop(url: hero.imageURL)
                            .frame(width: width, height: heroHeight)
                            .id(hero.id)
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
                        .fill(hero.id == currentID ? Color.white : Color.white.opacity(0.4))
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
                .animation(.easeInOut, value: currentID)
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
        guard let currentID,
              let index = items.firstIndex(where: { $0.id == currentID })
        else {
            withAnimation(.easeInOut) { currentID = items.first?.id }
            return
        }
        let next = items[(index + 1) % items.count].id
        withAnimation(.easeInOut(duration: 0.6)) { self.currentID = next }
    }

    private func retreat() {
        guard let currentID,
              let index = items.firstIndex(where: { $0.id == currentID })
        else {
            withAnimation(.easeInOut) { currentID = items.last?.id }
            return
        }
        let previous = items[(index - 1 + items.count) % items.count].id
        withAnimation(.easeInOut(duration: 0.6)) { self.currentID = previous }
    }
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
        // Binding to the parent's focus state for the hero surface, plus the
        // paging callbacks fired when the remote is swiped left / right.
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

    /// The title / overview / action block. On tvOS it's the label of the
    /// full-hero focusable surface; elsewhere it's a fixed overlay.
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
            // The carousel bleeds to the screen edges on tvOS, so pad the text
            // and buttons into the title-safe area (overscan is ~60pt).
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        #else
            .padding(.horizontal, isCompact ? 16 : 24)
            // Extra bottom inset so the (taller) stacked buttons clear the page
            // indicator instead of colliding with it / clipping at the edge.
            .padding(.bottom, 40)
        #endif
            // Cap the readable column on very wide windows; fill the width when
            // compact. Pin the block to the leading edge.
            .frame(maxWidth: isCompact ? .infinity : 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(tvOS)
        /// On tvOS the ENTIRE hero is one focusable control rather than a small
        /// Details button. This is the key to focus navigation: the tab bar's
        /// downward move is a geometric search, so it lands on whatever sits in
        /// the column below the tab item. A small leading-aligned button gets
        /// skipped in favour of a card directly below it; a full-width surface
        /// that spans the hero can't be missed. Selecting it opens Details and
        /// left/right pages the carousel (no horizontal neighbour to move to).
        @ViewBuilder
        private var heroSurface: some View {
            if let movie = hero.movie {
                heroLink(value: movie)
            } else if let series = hero.series {
                heroLink(value: series)
            }
        }

        /// The hero rendered as one full-WIDTH `NavigationLink`, pinned to the
        /// bottom of the artwork at its natural height — NOT full height. The
        /// width is what makes the tab bar's downward focus move land on it
        /// (it can't miss a full-width target). The height matters too: if the
        /// surface reached the top of the screen there'd be no room above it for
        /// the Focus Engine to move "up" into the tab bar, so we leave the
        /// artwork above it unfocusable. `HeroSurfaceButtonStyle` draws no focus
        /// highlight (otherwise tvOS washes the whole surface white) — the
        /// `detailsPill` carries the highlight instead.
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
