//
//  HomeHeroCarousel.swift
//  Lume
//
//  A Netflix / Apple TV-style hero carousel for the top of the home screen on
//  iOS and macOS. (tvOS uses the immersive `TVHomeScreen` instead.) Features
//  trending movies the user owns using wide TMDB backdrop artwork,
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

    @State private var currentID: String?
    @State private var isInteracting = false

    /// Fill of the active page indicator (0…1). Driven by `autoAdvance()` and
    /// reset on every page change, it doubles as the auto-advance clock so the
    /// loading-bar dot and the actual slide jump can never drift apart.
    @State private var progress: Double = 0

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

    private let heroHeight: CGFloat = 800

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

    /// Index of the resting slide among the real items — which dot is active.
    private var currentIndex: Int {
        items.firstIndex { $0.id == currentItemID } ?? 0
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
                    // Fixed overlay — no `.id`/`.transition` so a stable view can
                    // fade out/in via `infoOpacity` rather than cross-dissolving.
                    HeroInfo(hero: hero, isCompact: isCompact)
                        .opacity(infoOpacity)
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
        .onAppear {
            // Seed `displayedID` first so the initial assignment skips the crossfade.
            if displayedID == nil { displayedID = items.first?.id }
            if currentID == nil { currentID = items.first?.id }
            prefetchNeighbours()
        }
        .onChange(of: currentItemID) { _, _ in
            // Restart the loading bar on every page change — auto or manual.
            progress = 0
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
            HeroPageIndicator(
                count: items.count,
                activeIndex: currentIndex,
                progress: progress
            )
            .padding(.bottom, 14)
        }
    }

    // MARK: - Auto-advance

    /// Ticks the loading-bar progress forward and pages when it fills. Driving the
    /// jump off the same `progress` the indicator renders keeps the bar and the
    /// slide change perfectly in step (like UIKit's `UIPageControlTimerProgress`).
    private func autoAdvance() async {
        guard items.count > 1 else { return }
        let tick: Duration = .milliseconds(50)
        let total = Double(autoAdvanceInterval.components.seconds)
        // Fraction of the bar to add per tick: 50ms / 6s.
        let step = 0.05 / total
        while !Task.isCancelled {
            try? await Task.sleep(for: tick)
            if Task.isCancelled { return }
            // While the user is driving the carousel, hold the bar EMPTY rather
            // than frozen. Freezing it near full meant the first tick after they
            // let go fired `advance()` immediately — off a still-settling
            // `currentID` — which read as random forward/backward jumps. Keeping
            // it at zero guarantees a full dwell on the slide they land on.
            if isInteracting {
                progress = 0
                continue
            }
            if progress >= 1 {
                // Reset BEFORE paging so the next tick can't re-trigger an advance
                // in the window before `onChange(currentItemID)` resets it.
                progress = 0
                advance()
            } else {
                progress = min(progress + step, 1)
            }
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
    HomeHeroCarousel(items: items)
}

#Preview("Single Item") {
    let items = [
        HeroItem.movie(
            Movie(id: "preview-hero-3", streamId: 3, name: "The Dark Knight"),
            backdropURL: nil,
            overview: "When the menace known as the Joker wreaks havoc on Gotham."
        )
    ]
    HomeHeroCarousel(items: items)
}

#Preview("Empty") {
    HomeHeroCarousel(items: [])
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

// `HeroInfo` (the title / overview / buttons overlay) and the hero button styles
// live in `HeroInfo.swift`.
