//
//  HomeView+Navigation.swift
//  Lume
//
//  Home's navigation stack, driven from `DeepLinkRouter` so a pushed detail
//  screen survives the tab being unmounted (see `IdleUnmountingTab`). Split out
//  of HomeView.swift, which sits at SwiftLint's file-length limit.
//

import SwiftUI

extension HomeView {
    /// Previews have no router; pushes there simply don't persist.
    var homePath: Binding<NavigationPath> {
        guard let pathRouter else { return .constant(NavigationPath()) }
        return Binding(get: { pathRouter.homePath }, set: { pathRouter.homePath = $0 })
    }

    /// The Downloads row's "See All": pushes the full Downloads list.
    func showAllDownloads() {
        pathRouter?.homePath.append(HomeDownloadsRoute())
    }
}

/// Home's platform-specific presentations, kept out of the body's modifier
/// chain: an `#if` there gets reindented by SwiftFormat.
extension View {
    @ViewBuilder
    func homeHeroDestination(_ selection: Binding<HeroItem?>, animationNamespace: Namespace.ID) -> some View {
        #if os(tvOS)
            navigationDestination(item: selection) { hero in
                if let movie = hero.movie {
                    MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                } else if let series = hero.series {
                    SeriesDetailView(series: series, animationNamespace: animationNamespace)
                }
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func homePlayerCovers(
        playingMedia: Binding<PlayableMedia?>,
        multiViewLaunch: Binding<MultiViewLaunch?>
    ) -> some View {
        #if os(iOS) || os(tvOS)
            fullScreenCover(item: playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            .fullScreenCover(item: multiViewLaunch) { launch in
                MultiViewScreen(seed: launch.seed)
            }
        #else
            self
        #endif
    }
}
