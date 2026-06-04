//
//  MediaDetailComponents.swift
//  Lume
//
//  Shared building blocks for the Apple TV-style movie and series detail
//  screens: a full-bleed backdrop hero, the metadata line, the prominent
//  Play button, secondary action pills, an expandable synopsis, the cast row
//  and the "You May Also Like" poster row. Both MovieDetailView and
//  SeriesDetailView compose these so the two screens stay visually identical.
//

import SwiftUI

extension View {
    @ViewBuilder
    func matchedTransitionSourceIfAvailable(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Layout metrics

enum DetailMetrics {
    /// Horizontal inset for the content column under the hero.
    static let contentPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28

    /// Hero height for the available container size. The hero is taller on
    /// phones (portrait-friendly) and capped on wide windows so it never eats
    /// the whole screen.
    static func heroHeight(for size: CGSize) -> CGFloat {
        #if os(macOS)
            return min(max(size.height * 0.58, 360), 620)
        #else
            // Roughly 58% of the screen, but never so tall the synopsis is offscreen.
            return min(size.height * 0.58, size.width * 1.25)
        #endif
    }
}

// MARK: - Backdrop image

/// A wide artwork fill that prefers the TMDB backdrop and gracefully falls back
/// to the provider poster, then to a symbol. Mirrors the home hero treatment.
struct BackdropImage: View {
    let url: URL?
    var fallbackSymbol: String = "film"

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(Color.gray.opacity(0.25))
                        .overlay { ProgressView() }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                case .failure:
                    Rectangle().fill(Color.gray.opacity(0.25))
                        .overlay {
                            Image(systemName: fallbackSymbol)
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

// MARK: - Hero

/// The cinematic header: backdrop artwork dimmed by a bottom gradient, with the
/// title (or its wordmark logo), an optional tagline and the metadata line
/// pinned to the lower-left.
struct DetailHero: View {
    let title: String
    let backdropURL: URL?
    let posterFallbackURL: URL?
    var logoURL: URL?
    var tagline: String?
    let metadata: DetailMetadata
    let height: CGFloat
    var fallbackSymbol: String = "film"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BackdropImage(url: backdropURL ?? posterFallbackURL, fallbackSymbol: fallbackSymbol)

            LinearGradient(
                colors: [.clear, .black.opacity(0.2), .black.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 6) {
                TitleLogo(url: logoURL, title: title, maxWidth: 340, maxHeight: 96) {
                    Text(title)
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(radius: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .shadow(radius: 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                MetadataLineView(metadata: metadata, tint: .white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(radius: 4)
            }
            .padding(.horizontal, DetailMetrics.contentPadding)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }
}

// MARK: - Metadata

/// The pieces shown on the metadata line, all optional so callers only fill
/// what the title actually has.
struct DetailMetadata {
    var genre: String?
    var year: String?
    var duration: String?
    var seasonInfo: String?
    var rating: Double?
    var contentRating: String?

    var hasContent: Bool {
        genre != nil || year != nil || duration != nil || seasonInfo != nil
            || rating != nil || contentRating != nil
    }
}

/// Renders the metadata as a dot-separated line with a leading certification
/// chip and a star rating, e.g.  `PG-13 · Documentary · 2021 · 30m · ★ 8.4`.
struct MetadataLineView: View {
    let metadata: DetailMetadata
    var tint: Color = .secondary

    private var textPieces: [String] {
        var pieces: [String] = []
        if let genre = metadata.genre, !genre.isEmpty {
            // Genre lists can be long; keep the first two for the line.
            let trimmed = genre.split(separator: ",").prefix(2)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ", ")
            pieces.append(trimmed)
        }
        if let year = metadata.year, !year.isEmpty { pieces.append(year) }
        if let duration = metadata.duration, !duration.isEmpty { pieces.append(duration) }
        if let seasonInfo = metadata.seasonInfo, !seasonInfo.isEmpty { pieces.append(seasonInfo) }
        return pieces
    }

    var body: some View {
        HStack(spacing: 8) {
            if let cert = metadata.contentRating, !cert.isEmpty {
                Text(cert)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(tint.opacity(0.6), lineWidth: 1)
                    )
            }

            if !textPieces.isEmpty {
                Text(textPieces.joined(separator: "  ·  "))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let rating = metadata.rating, rating > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.caption2)
                    Text(String(format: "%.1f", rating))
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint)
    }
}

// MARK: - Buttons

/// The big, white, full-width primary action (Play / Resume).
struct PrimaryPlayButton: View {
    let title: String
    var systemImage: String = "play.fill"
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .controlSize(.large)
        .disabled(!isEnabled)
    }
}

/// A circular glass button for the floating navigation overlay (back, share…).
struct GlassIconButton: View {
    let systemImage: String
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Section header

struct DetailSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
    }
}

// MARK: - Expandable synopsis

/// A synopsis that collapses to a few lines with a "more" affordance. Uses a
/// length heuristic to decide whether the toggle is worth showing.
struct ExpandableText: View {
    let text: String
    var collapsedLineLimit: Int = 3

    @State private var isExpanded = false

    private var isExpandable: Bool {
        text.count > 160
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)

            if isExpandable {
                Button(isExpanded ? "less" : "more") {
                    isExpanded.toggle()
                }
                .font(.callout.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Cast

struct CastRow: View {
    let cast: [CastMember]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(cast) { member in
                    CastCard(member: member)
                }
            }
            .padding(.horizontal, DetailMetrics.contentPadding)
        }
    }
}

private struct CastCard: View {
    let member: CastMember

    var body: some View {
        VStack(spacing: 8) {
            AsyncImage(url: TMDBClient.profileURL(member.profilePath)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty where member.profilePath != nil:
                    Rectangle().fill(Color.gray.opacity(0.25)).overlay { ProgressView() }
                default:
                    Rectangle().fill(Color.gray.opacity(0.25))
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 78, height: 78)
            .clipShape(Circle())

            VStack(spacing: 2) {
                Text(member.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let role = member.role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(width: 92)
    }
}

// MARK: - Similar titles

/// Horizontal poster row for "You May Also Like". Reuses `HomeMediaItem` so the
/// destination links match the rest of the app.
struct SimilarRow: View {
    let items: [HomeMediaItem]
    var animationNamespace: Namespace.ID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(items) { item in
                    switch item {
                    case let .movie(movie):
                        NavigationLink(value: movie) {
                            DetailPosterCard(title: item.title, imageURL: item.imageURL)
                                .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                        }
                        .buttonStyle(.plain)
                    case let .series(series):
                        NavigationLink(value: series) {
                            DetailPosterCard(title: item.title, imageURL: item.imageURL)
                                .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                        }
                        .buttonStyle(.plain)
                    case .live:
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, DetailMetrics.contentPadding)
        }
    }
}

/// A poster-style card matching the home rows, for the similar-titles strip.
struct DetailPosterCard: View {
    let title: String
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(Color.gray.opacity(0.3)).overlay { ProgressView() }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .overlay {
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                                .font(.largeTitle)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 2)

            Text(title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)
        }
    }
}

// MARK: - Formatting helpers

enum DetailFormat {
    /// "1h 32m" / "45m" from a duration in seconds.
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// "45m" from a duration in seconds (episode rows).
    static func minutes(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return "\(max(seconds / 60, 1))m"
    }

    /// A four-digit year pulled from a release date string in any common shape.
    static func year(from dateString: String?) -> String? {
        guard let dateString else { return nil }
        if let match = dateString.range(of: #"\d{4}"#, options: .regularExpression) {
            return String(dateString[match])
        }
        return nil
    }

    /// A localized abbreviated date ("Mar 15, 2021") from a release-date string.
    static func date(from dateString: String?) -> String? {
        guard let dateString, !dateString.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            parser.dateFormat = format
            if let date = parser.date(from: dateString) {
                return date.formatted(date: .abbreviated, time: .omitted)
            }
        }
        return nil
    }
}

// MARK: - Previews

#Preview("DetailHero with TMDB") {
    DetailHero(
        title: "The Matrix",
        backdropURL: URL(string: "https://image.tmdb.org/t/p/w1280/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"),
        posterFallbackURL: nil,
        tagline: "Welcome to the Real World.",
        metadata: DetailMetadata(
            genre: "Action, Sci-Fi",
            year: "1999",
            duration: "2h 16m",
            rating: 8.7,
            contentRating: "R"
        ),
        height: 400
    )
}

#Preview("DetailHero without TMDB") {
    DetailHero(
        title: "The Matrix",
        backdropURL: nil,
        posterFallbackURL: nil,
        metadata: DetailMetadata(
            genre: "Action",
            year: "1999",
            rating: 8.7
        ),
        height: 400
    )
}

#Preview("MetadataLineView - Full") {
    MetadataLineView(
        metadata: DetailMetadata(
            genre: "Action, Sci-Fi",
            year: "1999",
            duration: "2h 16m",
            rating: 8.7,
            contentRating: "PG-13"
        )
    )
}

#Preview("MetadataLineView - Minimal") {
    MetadataLineView(
        metadata: DetailMetadata(
            year: "1999",
            rating: 6.5
        )
    )
}

#Preview("MetadataLineView - Empty") {
    MetadataLineView(metadata: DetailMetadata())
}

#Preview("PrimaryPlayButton - Enabled") {
    PrimaryPlayButton(title: "Play", action: {})
        .padding()
}

#Preview("PrimaryPlayButton - Disabled") {
    PrimaryPlayButton(title: "Play", isEnabled: false, action: {})
        .padding()
}

#Preview("PrimaryPlayButton - Resume") {
    PrimaryPlayButton(title: "Resume", systemImage: "play.fill", action: {})
        .padding()
}

#Preview("GlassIconButton") {
    HStack(spacing: 12) {
        GlassIconButton(systemImage: "chevron.left", accessibilityLabel: "Back", action: {})
        GlassIconButton(systemImage: "heart", accessibilityLabel: "Favorite", action: {})
        GlassIconButton(systemImage: "checkmark.circle", accessibilityLabel: "Watched", action: {})
    }
    .padding()
    .background(Color.black)
}

#Preview("ExpandableText - Short") {
    ExpandableText(text: "A short synopsis that doesn't need a more/less toggle.")
        .padding()
}

#Preview("ExpandableText - Long") {
    ExpandableText(
        text: "This is a very long synopsis that will definitely need a more/less toggle to expand or collapse "
            + "because it exceeds the character limit we've set. The quick brown fox jumps over the lazy dog. "
            + "This text keeps going and going until it crosses the threshold where the toggle becomes useful "
            + "for the user to read the full content without taking up too much space initially."
    )
    .padding()
}

#Preview("CastRow") {
    let movie = Movie(id: "preview", streamId: 1, name: "Preview")
    let cast = [
        CastMember(id: "preview-cast-0", tmdbPersonId: 1, name: "Keanu Reeves", role: "Neo", order: 0, movie: movie),
        CastMember(id: "preview-cast-1", tmdbPersonId: 2, name: "Laurence Fishburne", role: "Morpheus", order: 1, movie: movie),
        CastMember(id: "preview-cast-2", tmdbPersonId: 3, name: "Carrie-Anne Moss", role: "Trinity", order: 2, movie: movie)
    ]
    CastRow(cast: cast)
}

#Preview("SimilarRow") {
    let movie1 = Movie(id: "preview-sim-1", streamId: 1, name: "Similar Movie 1")
    let movie2 = Movie(id: "preview-sim-2", streamId: 2, name: "Similar Movie 2")
    SimilarRow(items: [.movie(movie1), .movie(movie2)])
}

#Preview("DetailPosterCard") {
    DetailPosterCard(
        title: "The Matrix",
        imageURL: URL(string: "https://image.tmdb.org/t/p/w185/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg")
    )
}

#Preview("DetailPosterCard - No Image") {
    DetailPosterCard(title: "No Poster", imageURL: nil)
}
