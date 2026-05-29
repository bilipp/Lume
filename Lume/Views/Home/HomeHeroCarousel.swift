//
//  HomeHeroCarousel.swift
//  Lume
//
//  A Netflix / Apple TV-style hero carousel for the top of the home screen.
//  Features trending movies the user owns using wide TMDB backdrop artwork,
//  auto-advancing every few seconds while honouring manual swipes.
//
//  Built on a paging ScrollView (`scrollTargetBehavior(.paging)` +
//  `scrollPosition`) rather than `TabView(.page)` so it works on macOS too,
//  where the page tab style is unavailable.
//

import SwiftUI

/// One featured movie in the hero carousel: the owned `Movie` plus the
/// TMDB-sourced wide artwork and copy that make it look cinematic.
struct HeroMovie: Identifiable, Hashable {
    let movie: Movie
    let backdropURL: URL?
    let overview: String

    var id: String { movie.id }

    /// Prefer the wide TMDB backdrop; fall back to the provider poster so a
    /// title without a backdrop still renders something.
    var imageURL: URL? {
        backdropURL ?? URL(string: movie.streamIcon ?? "")
    }
}

struct HomeHeroCarousel: View {
    let movies: [HeroMovie]
    let onPlay: (Movie) -> Void

    @State private var currentID: String?
    @State private var isInteracting = false

    private let autoAdvanceInterval: Duration = .seconds(6)

    private var heroHeight: CGFloat {
        #if os(macOS)
        460
        #else
        440
        #endif
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(movies) { hero in
                    HeroPage(hero: hero, onPlay: onPlay)
                        .containerRelativeFrame(.horizontal)
                        .id(hero.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .frame(height: heroHeight)
        .clipped()
        .overlay(alignment: .bottom) { pageIndicator }
        .onScrollPhaseChange { _, newPhase, _ in
            isInteracting = newPhase != .idle
        }
        .onAppear {
            if currentID == nil { currentID = movies.first?.id }
        }
        .task(id: movies.count) {
            await autoAdvance()
        }
    }

    // MARK: - Page indicator

    @ViewBuilder
    private var pageIndicator: some View {
        if movies.count > 1 {
            HStack(spacing: 8) {
                ForEach(movies) { hero in
                    Circle()
                        .fill(hero.id == currentID ? Color.white : Color.white.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 14)
            .animation(.easeInOut, value: currentID)
        }
    }

    // MARK: - Auto-advance

    private func autoAdvance() async {
        guard movies.count > 1 else { return }
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
              let index = movies.firstIndex(where: { $0.id == currentID }) else {
            withAnimation(.easeInOut) { self.currentID = movies.first?.id }
            return
        }
        let next = movies[(index + 1) % movies.count].id
        withAnimation(.easeInOut(duration: 0.6)) { self.currentID = next }
    }
}

// MARK: - Single hero page

private struct HeroPage: View {
    let hero: HeroMovie
    let onPlay: (Movie) -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            // Darken the bottom so the title and buttons stay legible over
            // any artwork.
            LinearGradient(
                colors: [.clear, .black.opacity(0.15), .black.opacity(0.8)],
                startPoint: .center,
                endPoint: .bottom
            )
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
    }

    private var backdrop: some View {
        AsyncImage(url: hero.imageURL) { phase in
            switch phase {
            case .empty:
                Rectangle()
                    .fill(Color.gray.opacity(0.25))
                    .overlay { ProgressView() }
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hero.movie.name)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .shadow(radius: 6)

            if !hero.overview.isEmpty {
                Text(hero.overview)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
            }

            HStack(spacing: 12) {
                Button {
                    onPlay(hero.movie)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)

                NavigationLink(value: hero.movie) {
                    Label("Details", systemImage: "info.circle")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
