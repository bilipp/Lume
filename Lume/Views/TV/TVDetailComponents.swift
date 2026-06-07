//
//  TVDetailComponents.swift
//  Lume
//
//  tvOS-only building blocks for the Apple TV+/App-Store-style movie and series
//  detail screens. These mirror the Figma "TV App Asset Template" layout: a
//  full-bleed backdrop with a three-column info band (action button · title +
//  synopsis + rating · metadata key/values), then horizontal rails for
//  episodes, cast and related titles, plus an "About" / ratings block.
//
//  Everything here is tuned for the 10-foot UI and the focus engine: cards lift
//  and gain a shadow when focused, the primary Play button is the default focus,
//  and rails are wrapped in focus sections by the composing views.
//

#if os(tvOS)

    import Foundation
    import SwiftUI

    // MARK: - Layout metrics

    enum TVDetailMetrics {
        /// Title-safe horizontal inset for content under the full-bleed hero.
        static let horizontalInset: CGFloat = 90
        /// Vertical gap between top-level sections under the hero.
        static let sectionSpacing: CGFloat = 56
        /// Gap between cards inside a horizontal rail.
        static let railSpacing: CGFloat = 40
        /// Height of the cinematic hero (leaves the rails just below the fold).
        static let heroHeight: CGFloat = 900
        /// Bottom padding of the hero info band.
        static let heroBottomInset: CGFloat = 80

        // Card sizes
        static let episodeCardWidth: CGFloat = 392
        static let episodeStillHeight: CGFloat = 220
        static let posterCardWidth: CGFloat = 240
        static let posterCardHeight: CGFloat = 360
        static let castCardWidth: CGFloat = 200
        static let castAvatar: CGFloat = 160
    }

    // MARK: - Backdrop

    /// A full-bleed artwork fill that prefers the TMDB backdrop and gracefully
    /// degrades to the provider poster, then to a symbol.
    struct TVDetailBackdrop: View {
        let url: URL?
        var fallbackSymbol: String = "film"

        var body: some View {
            GeometryReader { geo in
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Rectangle().fill(Color.black.opacity(0.6))
                            .overlay { ProgressView() }
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    case .failure:
                        Rectangle().fill(Color.black.opacity(0.6))
                            .overlay {
                                Image(systemName: fallbackSymbol)
                                    .font(.system(size: 80))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    // MARK: - Star rating

    /// Five-star rating (with halves) plus the numeric value, on a 0…5 scale.
    struct TVStarRating: View {
        let rating: Double // 0...5
        var showsValue: Bool = true

        var body: some View {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0 ..< 5, id: \.self) { index in
                        Image(systemName: symbol(for: index))
                    }
                }
                .font(.system(size: 26))
                .foregroundStyle(.white)

                if showsValue {
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }

        private func symbol(for index: Int) -> String {
            let position = Double(index)
            if rating >= position + 1 { return "star.fill" }
            if rating >= position + 0.5 { return "star.leadinghalf.filled" }
            return "star"
        }
    }

    // MARK: - Badge

    /// A pill badge for the content rating or a highlight tag.
    struct TVBadge: View {
        let text: String
        var filled: Bool = false

        var body: some View {
            Text(text)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(filled ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(0.5), lineWidth: filled ? 0 : 2)
                        )
                )
        }
    }

    // MARK: - Metadata column

    struct TVMetaItem: Identifiable {
        var id: String {
            label
        }

        let label: String
        let value: String
    }

    /// The right-hand key/value column in the hero band
    /// (e.g. Released · Genre · Director).
    struct TVMetaColumn: View {
        let items: [TVMetaItem]

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(item.label)).textCase(.uppercase)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(item.value)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Hero band

    /// The cinematic header: a full-bleed backdrop dimmed by a bottom gradient,
    /// with a three-column info band pinned to the lower edge. The `actions`
    /// slot holds the Play button and any secondary buttons.
    struct TVDetailHero<Actions: View>: View {
        let title: String
        let backdropURL: URL?
        let posterFallbackURL: URL?
        var logoURL: URL?
        var tagline: String?
        var rating: Double? // 0...5
        var badge: String?
        let metaItems: [TVMetaItem]
        var fallbackSymbol: String = "film"
        @ViewBuilder var actions: () -> Actions

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                TVDetailBackdrop(url: backdropURL ?? posterFallbackURL, fallbackSymbol: fallbackSymbol)

                // Bottom scrim for legibility over bright artwork.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                HStack(alignment: .top, spacing: 56) {
                    // Action column
                    VStack(alignment: .leading, spacing: 18) {
                        actions()
                    }
                    .frame(width: 420, alignment: .leading)

                    // Title + synopsis + rating
                    VStack(alignment: .leading, spacing: 14) {
                        TitleLogo(url: logoURL, title: title, maxWidth: 820, maxHeight: 150) {
                            Text(title)
                                .font(.system(size: 52, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                                .shadow(radius: 10)
                        }

                        if let tagline, !tagline.isEmpty {
                            Text(tagline)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }

                        HStack(spacing: 20) {
                            if let rating, rating > 0 {
                                TVStarRating(rating: rating)
                            }
                            if let badge, !badge.isEmpty {
                                TVBadge(text: badge)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Metadata key/values
                    if !metaItems.isEmpty {
                        TVMetaColumn(items: metaItems)
                            .frame(width: 360, alignment: .leading)
                    }
                }
                .padding(.horizontal, TVDetailMetrics.horizontalInset)
                .padding(.bottom, TVDetailMetrics.heroBottomInset)
            }
            .frame(maxWidth: .infinity)
            .frame(height: TVDetailMetrics.heroHeight)
            .clipped()
        }
    }

    // MARK: - Section header

    struct TVSectionHeader: View {
        let title: LocalizedStringKey

        var body: some View {
            Text(title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Episode card

    /// A large 16:9 episode card for the horizontal episode rail: still image
    /// with a resume bar, then number/title, runtime and a two-line synopsis.
    struct TVEpisodeCard: View {
        let episode: Episode
        var onPlay: () -> Void
        var onToggleWatched: () -> Void = {}
        var onMarkPreviousWatched: () -> Void = {}
        var onMarkFollowingUnwatched: () -> Void = {}

        var body: some View {
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 14) {
                    still
                    VStack(alignment: .leading, spacing: 6) {
                        Text(heading)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let metaLine {
                            Text(metaLine)
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }

                        if let plot = episode.plot, !plot.isEmpty {
                            Text(plot)
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                        }
                    }
                    .frame(width: TVDetailMetrics.episodeCardWidth, alignment: .leading)
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .contextMenu {
                EpisodeWatchedMenu(
                    episode: episode,
                    onToggleWatched: onToggleWatched,
                    onMarkPreviousWatched: onMarkPreviousWatched,
                    onMarkFollowingUnwatched: onMarkFollowingUnwatched
                )
            }
        }

        private var still: some View {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(url: URL(string: episode.movieImage ?? ""), maxPixelSize: 640) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty where episode.movieImage != nil:
                        Rectangle().fill(Color.white.opacity(0.08)).overlay { ProgressView() }
                    default:
                        Rectangle().fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "play.tv")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    }
                }
                .frame(width: TVDetailMetrics.episodeCardWidth, height: TVDetailMetrics.episodeStillHeight)
                .clipped()

                if let progress = resumeFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }

                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: TVDetailMetrics.episodeCardWidth, height: TVDetailMetrics.episodeStillHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }

        private var heading: String {
            episode.title.isEmpty ? String(localized: "Episode \(episode.episodeNum)") : "\(episode.episodeNum). \(episode.title)"
        }

        private var metaLine: String? {
            let parts = [
                DetailFormat.date(from: episode.airDate),
                DetailFormat.minutes(episode.durationSecs)
            ].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
        }

        private var resumeFraction: Double? {
            guard episode.watchProgress > 0,
                  let duration = episode.durationSecs, duration > 0,
                  !episode.isWatched else { return nil }
            return min(episode.watchProgress / Double(duration), 1)
        }
    }

    // MARK: - Cast card

    struct TVCastCard: View {
        let member: CastMember

        @FocusState private var isFocused: Bool

        var body: some View {
            VStack(spacing: 14) {
                CachedAsyncImage(url: TMDBClient.profileURL(member.profilePath, size: "w342"), maxPixelSize: 160) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty where member.profilePath != nil:
                        Rectangle().fill(Color.white.opacity(0.08)).overlay { ProgressView() }
                    default:
                        Rectangle().fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    }
                }
                .frame(width: TVDetailMetrics.castAvatar, height: TVDetailMetrics.castAvatar)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
                )

                VStack(spacing: 4) {
                    Text(member.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let role = member.role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(width: TVDetailMetrics.castCardWidth)
            }
            .focusable(true)
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }

    // MARK: - Poster card

    /// A poster-style card for the "You May Also Like" / collection rails.
    struct TVPosterCard: View {
        let title: String
        let imageURL: URL?

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                CachedAsyncImage(url: imageURL, maxPixelSize: PosterCardMetrics.posterHeight) { phase in
                    switch phase {
                    case .empty:
                        Rectangle().fill(Color.white.opacity(0.08)).overlay { ProgressView() }
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle().fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "film")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: TVDetailMetrics.posterCardWidth, height: TVDetailMetrics.posterCardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: TVDetailMetrics.posterCardWidth, alignment: .leading)
            }
        }
    }

    // MARK: - Info card

    /// A card listing supplementary key/value information (Director, Genre…).
    struct TVInfoCard: View {
        let title: LocalizedStringKey
        let items: [TVMetaItem]

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(item.label)).textCase(.uppercase)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(item.value)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
        }
    }

    // MARK: - Rail helper

    /// A titled horizontal rail wrapped in a focus section so the remote moves
    /// cleanly between sections.
    struct TVRail<Content: View>: View {
        let title: LocalizedStringKey
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                TVSectionHeader(title: title)
                    .padding(.horizontal, TVDetailMetrics.horizontalInset)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVDetailMetrics.railSpacing) {
                        content()
                    }
                    .padding(.horizontal, TVDetailMetrics.horizontalInset)
                    .padding(.vertical, 24) // breathing room for the focus lift
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - Loading

    /// Full-screen placeholder shown while TMDB enrichment is fetched on first
    /// visit, mirroring the loading gate the iOS / macOS detail screens use.
    /// Tuned for the 10-foot UI with a large spinner and title.
    struct TVDetailLoadingView: View {
        let title: String

        var body: some View {
            VStack(spacing: 36) {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.6)

                Text(title)
                    .font(.system(size: 44, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                Text("Loading details…")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, TVDetailMetrics.horizontalInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

#endif
