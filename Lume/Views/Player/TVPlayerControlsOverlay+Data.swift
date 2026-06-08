//
//  TVPlayerControlsOverlay+Data.swift
//  Lume
//
//  Content resolution and derived display data for `TVPlayerControlsOverlay`.
//  Split out from the view file to keep each under the SwiftLint file-length
//  threshold; the overlay's state is `internal` (not `private`) so this
//  same-module extension can read it.
//

#if os(tvOS)

    import Foundation
    import SwiftData
    import SwiftUI

    extension TVPlayerControlsOverlay {
        var isSeries: Bool {
            if case .episode = media.contentRef { true } else { false }
        }

        func resolveContent() {
            // A stream swap invalidates any in-flight scrub.
            isScrubbing = false
            scrubResetTask?.cancel()
            scrubResetTask = nil
            episode = nil
            seasonEpisodes = []
            movie = nil
            liveStream = nil
            epgNow = nil
            epgNext = nil
            seriesPlaylist = nil
            recentChannels = []
            recentNowTitles = [:]

            switch media.contentRef {
            case .episode:
                guard let resolved = TVPlayerContent.episode(for: media.contentRef, in: modelContext) else { return }
                episode = resolved
                seasonEpisodes = TVPlayerContent.seasonEpisodes(for: resolved)
                seriesPlaylist = TVPlayerContent.playlist(for: resolved.series, in: modelContext)
            case .movie:
                movie = TVPlayerContent.movie(for: media.contentRef, in: modelContext)
            case .live:
                guard let stream = TVPlayerContent.liveStream(for: media.contentRef, in: modelContext) else { return }
                liveStream = stream
                let listings = TVPlayerContent.epgListings(channelId: stream.epgChannelId, in: modelContext)
                let now = Date()
                epgNow = listings.first { $0.start <= now && now < $0.end }
                epgNext = listings.first { $0.start > now }
                recentChannels = TVPlayerContent.recentChannels(in: modelContext)
                recentNowTitles = TVPlayerContent.nowProgrammeTitles(for: recentChannels, in: modelContext)
            }
        }

        // MARK: Captions

        var topCaption: String? {
            if media.isLive { return epgNow?.title }
            if isSeries { return media.subtitle }
            return nil
        }

        var techCaption: String {
            coordinator.videoInfo?.captionParts.joined(separator: "  ·  ") ?? ""
        }

        // MARK: Scrubbing (VOD)

        /// Select toggles scrub mode: the first press enters (and pauses), the
        /// second commits the seek.
        func toggleScrub() {
            if isScrubbing { commitScrub() } else { beginScrub() }
        }

        /// Enter scrub mode: remember the play state, pause, and seed the
        /// target at the current position. Treated like an open panel so the
        /// controls stay up and the Menu button routes back here to cancel.
        func beginScrub() {
            guard !media.isLive else { return }
            wasPlayingBeforeScrub = coordinator.isPlaying
            if coordinator.isPlaying { onTogglePlay() }
            scrubTarget = clock.current.isFinite ? clock.current : 0
            scrubStepLevel = 0
            scrubLastDirection = nil
            onPanelOpenChange(true)
            withAnimation(.easeOut(duration: 0.15)) { isScrubbing = true }
        }

        /// Commit the seek and leave scrub mode, resuming playback if it had
        /// been playing when scrubbing began.
        func commitScrub() {
            let target = min(max(scrubTarget, 0), max(clock.duration, 0))
            coordinator.seek(to: target)
            clock.current = target
            finishScrub(resume: wasPlayingBeforeScrub)
        }

        /// Abort the scrub (Menu press) without seeking, restoring the prior
        /// play state.
        func cancelScrub() {
            finishScrub(resume: wasPlayingBeforeScrub)
        }

        private func finishScrub(resume: Bool) {
            scrubResetTask?.cancel()
            scrubResetTask = nil
            withAnimation(.easeOut(duration: 0.15)) { isScrubbing = false }
            onPanelOpenChange(false)
            if resume, !coordinator.isPlaying { onTogglePlay() }
            focus = .scrubber
            onResetHideTimer()
        }

        /// Step the scrub target on a left/right press. The step grows with
        /// sustained input in one direction and decays after a brief pause.
        func moveScrub(_ direction: MoveCommandDirection) {
            guard isScrubbing, clock.duration > 0 else { return }
            let sign: Double
            switch direction {
            case .left: sign = -1
            case .right: sign = 1
            default: return
            }
            if direction != scrubLastDirection { scrubStepLevel = 0 }
            scrubLastDirection = direction
            scrubStepLevel = min(scrubStepLevel + 1, 40)
            // A single tap nudges ~30s; a held d-pad ramps to ~20 min/press, so
            // even a long movie crosses in a second or two of sustained input.
            let step = 30.0 * Double(scrubStepLevel)
            scrubTarget = min(max(scrubTarget + sign * step, 0), clock.duration)
            onResetHideTimer()

            scrubResetTask?.cancel()
            scrubResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                scrubStepLevel = 0
                scrubLastDirection = nil
            }
        }

        // MARK: Episode navigation

        private var currentEpisodeIndex: Int? {
            guard let episode else { return nil }
            return seasonEpisodes.firstIndex { $0.id == episode.id }
        }

        var previousEpisode: Episode? {
            guard let index = currentEpisodeIndex, index > 0 else { return nil }
            return seasonEpisodes[index - 1]
        }

        var nextEpisode: Episode? {
            guard let index = currentEpisodeIndex, index + 1 < seasonEpisodes.count else { return nil }
            return seasonEpisodes[index + 1]
        }

        // MARK: Actions

        func select(episode chosen: Episode) {
            guard let playlist = seriesPlaylist,
                  let newMedia = PlayableMedia.from(episode: chosen, playlist: playlist) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { openTab = nil }
            onPanelOpenChange(false)
            focus = .transport
            onSelectMedia(newMedia)
        }

        func select(channel stream: LiveStream) {
            guard let playlist = LiveChannelNavigator.playlist(for: stream, in: modelContext),
                  let newMedia = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { openTab = nil }
            onPanelOpenChange(false)
            focus = .transport
            onSelectMedia(newMedia)
        }

        func toggle(tab kind: TabKind) {
            withAnimation(.easeInOut(duration: 0.22)) {
                openTab = (openTab == kind) ? nil : kind
            }
            switch openTab {
            case .episodes:
                onPanelOpenChange(true)
                focus = .episode(episode?.id ?? seasonEpisodes.first?.id ?? "")
            case .recent:
                onPanelOpenChange(true)
                focus = .channel(liveStream?.id ?? recentChannels.first?.id ?? "")
            case .info:
                onPanelOpenChange(true)
                focus = infoPrimaryAction != nil ? .infoPrimary : .panelClose
            case nil:
                onPanelOpenChange(false)
                focus = .tab(tabKinds.firstIndex(of: kind) ?? 0)
            }
        }

        func closePanel() {
            let previous = openTab
            withAnimation(.easeInOut(duration: 0.22)) { openTab = nil }
            onPanelOpenChange(false)
            if let previous, let index = tabKinds.firstIndex(of: previous) {
                focus = .tab(index)
            } else {
                focus = .transport
            }
        }

        // MARK: Info panel data

        var infoTitle: String {
            if media.isLive { return epgNow?.title ?? media.title }
            if isSeries { return episodeHeading ?? media.title }
            return media.title
        }

        private var episodeHeading: String? {
            guard let episode else { return nil }
            let base = episode.title.isEmpty ? String(localized: "Episode \(episode.episodeNum)") : episode.title
            return "S\(episode.seasonNum) E\(episode.episodeNum) · \(base)"
        }

        var infoSubtitle: String? {
            (media.isLive || isSeries) ? media.title : nil
        }

        var infoSynopsis: String? {
            if media.isLive { return epgNow?.listingDescription }
            if isSeries { return episode?.plot }
            return movie?.plot
        }

        var infoMetaLine: String? {
            if media.isLive {
                guard let epgNow else { return nil }
                var line = "\(clock(epgNow.start)) – \(clock(epgNow.end))"
                if let epgNext { line += "   ·   " + String(localized: "Next: \(epgNext.title)") }
                return line
            }
            if isSeries {
                let parts = [
                    DetailFormat.date(from: episode?.airDate),
                    DetailFormat.duration(episode?.durationSecs)
                ].compactMap(\.self)
                return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
            }
            let parts = [
                shortGenre(movie?.genre),
                DetailFormat.year(from: movie?.releaseDate),
                DetailFormat.duration(movie?.durationSecs)
            ].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
        }

        var infoBadges: [String] {
            var badges: [String] = []
            if let rating = contentRatingBadge, !rating.isEmpty { badges.append(rating) }
            if let info = coordinator.videoInfo {
                if !info.qualityTag.isEmpty { badges.append(info.qualityTag) }
                if let codec = info.codec, !codec.isEmpty { badges.append(codec.uppercased()) }
            }
            return badges
        }

        private var contentRatingBadge: String? {
            isSeries ? episode?.series?.contentRating : movie?.contentRating
        }

        var infoPrimaryAction: TVPlayerInfoAction? {
            guard !media.isLive else { return nil }
            return TVPlayerInfoAction(title: "Restart", systemImage: "gobackward") {
                coordinator.seek(to: 0)
                clock.current = 0
                closePanel()
                onResetHideTimer()
            }
        }

        var infoSecondaryAction: TVPlayerInfoAction? {
            TVPlayerInfoAction(
                title: isFavorite ? "In Favorites" : "Favorite",
                systemImage: isFavorite ? "heart.fill" : "heart",
                perform: toggleFavorite
            )
        }

        private var isFavorite: Bool {
            if isSeries { return episode?.series?.isFavorite ?? false }
            if media.isLive { return liveStream?.isFavorite ?? false }
            return movie?.isFavorite ?? false
        }

        private func toggleFavorite() {
            if isSeries, let series = episode?.series {
                series.isFavorite.toggle()
                series.addedToWatchlistDate = series.isFavorite ? Date() : nil
            } else if media.isLive, let liveStream {
                liveStream.isFavorite.toggle()
            } else if let movie {
                movie.isFavorite.toggle()
                movie.addedToWatchlistDate = movie.isFavorite ? Date() : nil
            }
            try? modelContext.save()
            onResetHideTimer()
        }

        // MARK: Formatting

        private func shortGenre(_ genre: String?) -> String? {
            guard let genre, !genre.isEmpty else { return nil }
            return genre.split(separator: ",").prefix(2)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ", ")
        }

        private func clock(_ date: Date) -> String {
            date.formatted(date: .omitted, time: .shortened)
        }
    }

#endif
