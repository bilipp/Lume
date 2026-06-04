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

    @State private var currentID: String?
    @State private var isInteracting = false

    private let autoAdvanceInterval: Duration = .seconds(6)
    /// Width below which the hero switches to the stacked, full-width layout.
    private let compactWidthThreshold: CGFloat = 600

    #if os(macOS)
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
                    // Fixed overlay in normal layout — text wraps to `width`.
                    HeroInfo(hero: hero, isCompact: isCompact, onPlayMovie: onPlayMovie)
                        .id(hero.id)
                        .transition(.opacity)
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
            // tvOS applies overscan safe-area insets (~60pt) on every edge. The
            // enclosing ScrollView only ignores the top edge, which leaves the
            // hero inset on the left/right and stops it from spanning the full
            // screen. Bleed past the horizontal insets so the artwork reaches
            // both edges; HeroInfo keeps its own title-safe padding.
            .ignoresSafeArea(edges: .horizontal)
        #endif
            .onAppear {
                if currentID == nil { currentID = items.first?.id }
            }
            .task(id: items.count) {
                await autoAdvance()
            }
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
                isInteracting = newPhase != .idle
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
            advance()
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
            AsyncImage(url: url) { phase in
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

    var body: some View {
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

    @ViewBuilder
    private var actionButtons: some View {
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
    }

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

    @ViewBuilder
    private func playLabel(fullWidth: Bool) -> some View {
        // On tvOS the glass style owns the foreground colour (it flips to black
        // on focus) and sizing, so keep the label plain there.
        #if os(tvOS)
            Label("Play", systemImage: "play.fill")
                .fontWeight(.semibold)
        #else
            Label("Play", systemImage: "play.fill")
                .fontWeight(.semibold)
                .foregroundStyle(.black)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        #endif
    }

    @ViewBuilder
    private func detailsLabel(fullWidth: Bool) -> some View {
        #if os(tvOS)
            Label("Details", systemImage: "info.circle")
                .fontWeight(.semibold)
        #else
            Label("Details", systemImage: "info.circle")
                .fontWeight(.semibold)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        #endif
    }
}

// MARK: - Hero button styles

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
