//
//  TVPlayerPanels.swift
//  Lume
//
//  The two slide-up panels for the tvOS player overlay and their supporting
//  controls. The "Episodes" tab raises a horizontal rail of episode cards
//  (mirroring the Apple TV "Follow On" template); the "Info" tab raises an
//  information card with artwork, synopsis, metadata badges and a couple of
//  contextual actions (mirroring the "Info Tab" template).
//

#if os(tvOS)

    import SwiftUI

    // MARK: - Focus targets

    /// Every focusable element in the tvOS player overlay. A single
    /// `@FocusState` of this type is owned by the overlay and shared with the
    /// panels so focus can be moved programmatically as panels open and close.
    enum TVPlayerFocus: Hashable {
        case transport
        case skipBackward
        case skipForward
        case previousItem
        case nextItem
        case tab(Int)
        case audio
        case subtitles
        case panelClose
        case episode(String)
        case infoPrimary
        case infoSecondary
    }

    // MARK: - Button styles

    /// A circular transport button rendered in genuine Liquid Glass. Idle it is
    /// a clear lensing disc; on focus the glass brightens (white tint), the glyph
    /// flips to black and the control lifts — the player-overlay counterpart to
    /// the detail screens' styles, following the tvOS "glass on focus" pattern.
    struct TVPlayerCircleButtonStyle: ButtonStyle {
        var diameter: CGFloat = 60
        var glyphSize: CGFloat = 24

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, diameter: diameter, glyphSize: glyphSize)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let diameter: CGFloat
            let glyphSize: CGFloat
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                let pressed = configuration.isPressed
                configuration.label
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .frame(width: diameter, height: diameter)
                    .glassEffect(glass, in: .circle)
                    .scaleEffect(pressed ? 1.05 : (isFocused ? 1.14 : 1.0))
                    .opacity(isEnabled ? 1 : 0.35)
                    .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
                    .animation(.easeOut(duration: 0.1), value: pressed)
            }

            /// Interactive so the material lenses and lifts under interaction;
            /// white-tinted on focus to read as the highlighted control without
            /// collapsing into a flat opaque fill.
            private var glass: Glass {
                isFocused
                    ? .regular.tint(.white).interactive()
                    : .regular.interactive()
            }
        }
    }

    // MARK: - Episodes panel

    /// The "Episodes" slide-up: a close button above a horizontal rail of the
    /// current season's episodes. The episode that is currently playing is
    /// marked, and picking another starts it.
    struct TVPlayerEpisodesPanel: View {
        let episodes: [Episode]
        let currentEpisodeID: String?
        var focus: FocusState<TVPlayerFocus?>.Binding
        let onSelect: (Episode) -> Void
        let onClose: () -> Void

        /// Still (180) + spacing + heading + meta + the focus-lift breathing
        /// room. Pinned so the horizontal rail doesn't stretch vertically and
        /// drag the panel up to the top of the screen.
        private let railHeight: CGFloat = 300

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(TVPlayerCircleButtonStyle(diameter: 52, glyphSize: 20))
                .focused(focus, equals: .panelClose)
                .accessibilityLabel("Close episodes")

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 30) {
                        ForEach(episodes) { episode in
                            TVPlayerEpisodeCard(
                                episode: episode,
                                isCurrent: episode.id == currentEpisodeID,
                                action: { onSelect(episode) }
                            )
                            .focused(focus, equals: .episode(episode.id))
                        }
                    }
                    .padding(.vertical, 18)
                }
                .frame(height: railHeight)
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    /// A compact 16:9 episode card for the in-player rail.
    struct TVPlayerEpisodeCard: View {
        let episode: Episode
        let isCurrent: Bool
        let action: () -> Void

        private let cardWidth: CGFloat = 320
        private let stillHeight: CGFloat = 180

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 10) {
                    still
                    Text(heading)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let metaLine {
                        Text(metaLine)
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
        }

        private var still: some View {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: URL(string: episode.movieImage ?? ""), maxPixelSize: cardWidth) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty where episode.movieImage != nil:
                        Rectangle().fill(Color.white.opacity(0.08)).overlay { ProgressView() }
                    default:
                        Rectangle().fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "play.tv")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    }
                }
                .frame(width: cardWidth, height: stillHeight)
                .clipped()

                if let progress = resumeFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }

                if isCurrent {
                    Text("NOW PLAYING")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white))
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: cardWidth, height: stillHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(isCurrent ? 0.9 : 0), lineWidth: 3)
            )
        }

        private var heading: String {
            // The numbered-title branch is content and stays verbatim; only the
            // "Episode N" fallback is a translatable label.
            episode.title.isEmpty
                ? String(localized: "Episode \(episode.episodeNum)")
                : "\(episode.episodeNum). \(episode.title)"
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

    // MARK: - Info panel

    /// A contextual action shown on the right of the information panel.
    struct TVPlayerInfoAction {
        let title: LocalizedStringKey
        var systemImage: String?
        let perform: () -> Void
    }

    /// The "Info" slide-up: artwork + title + synopsis + metadata badges on the
    /// left, with up to two contextual action buttons on the right.
    struct TVPlayerInfoPanel: View {
        let title: String
        var subtitle: String?
        var synopsis: String?
        var metaLine: String?
        var badges: [String]
        var posterURL: URL?
        var primaryAction: TVPlayerInfoAction?
        var secondaryAction: TVPlayerInfoAction?
        var focus: FocusState<TVPlayerFocus?>.Binding
        let onClose: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(TVPlayerCircleButtonStyle(diameter: 52, glyphSize: 20))
                .focused(focus, equals: .panelClose)
                .accessibilityLabel("Close information")

                HStack(alignment: .top, spacing: 36) {
                    artwork
                    details
                    if primaryAction != nil || secondaryAction != nil {
                        actions
                            .frame(width: 380)
                    }
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
            }
            .focusSection()
        }

        @ViewBuilder
        private var artwork: some View {
            if let posterURL {
                CachedAsyncImage(url: posterURL, maxPixelSize: 220) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                    }
                }
                .frame(width: 220, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }

        private var details: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                if let synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                }

                if metaLine != nil || !badges.isEmpty {
                    HStack(spacing: 12) {
                        if let metaLine, !metaLine.isEmpty {
                            Text(metaLine)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        ForEach(badges, id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(.white.opacity(0.5), lineWidth: 1.5)
                                )
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var actions: some View {
            VStack(spacing: 16) {
                if let primaryAction {
                    Button(action: primaryAction.perform) {
                        actionLabel(primaryAction)
                    }
                    .buttonStyle(TVGlassButtonStyle())
                    .focused(focus, equals: .infoPrimary)
                }
                if let secondaryAction {
                    Button(action: secondaryAction.perform) {
                        actionLabel(secondaryAction)
                    }
                    .buttonStyle(TVGlassButtonStyle())
                    .focused(focus, equals: .infoSecondary)
                }
            }
        }

        @ViewBuilder
        private func actionLabel(_ action: TVPlayerInfoAction) -> some View {
            if let systemImage = action.systemImage {
                Label(action.title, systemImage: systemImage)
            } else {
                Text(action.title)
            }
        }
    }

#endif
