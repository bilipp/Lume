//
//  MovieDetailView+Sources.swift
//  Lume
//
//  Which copy of a grouped movie Play opens; the shared logic lives in
//  `TitleGroupMovieDetail`.
//

import SwiftUI

extension MovieDetailView: TitleGroupMovieDetail {
    func presentPendingMedia() {
        guard let media = pendingMedia else { return }
        pendingMedia = nil
        playingMedia = media
    }
}
