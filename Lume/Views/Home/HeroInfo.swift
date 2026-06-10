//
//  HeroInfo.swift
//  Lume
//
//  The title / overview / action block overlaid on `HomeHeroCarousel`. On tvOS
//  the whole block is a single focusable hero surface; on iOS / macOS it exposes
//  separate Play and Details buttons.
//

import SwiftUI

// MARK: - Title / overview / buttons

struct HeroInfo: View {
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
