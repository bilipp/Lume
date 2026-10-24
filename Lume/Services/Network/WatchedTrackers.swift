//
//  WatchedTrackers.swift
//  Lume
//
//  One entry point for pushing a watched-state change to every tracker
//  integration (Trakt, Simkl, MDBList), so the player and the detail screens
//  don't each list the services. Each service no-ops when it isn't connected.
//

enum WatchedTrackers {
    static func sync(movie: Movie, watched: Bool) {
        TraktService.shared.syncWatched(movie: movie, watched: watched)
        SimklService.shared.syncWatched(movie: movie, watched: watched)
        MDBListService.shared.syncWatched(movie: movie, watched: watched)
    }

    static func sync(episode: Episode, watched: Bool) {
        TraktService.shared.syncWatched(episode: episode, watched: watched)
        SimklService.shared.syncWatched(episode: episode, watched: watched)
        MDBListService.shared.syncWatched(episode: episode, watched: watched)
    }
}
