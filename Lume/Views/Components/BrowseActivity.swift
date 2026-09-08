//
//  BrowseActivity.swift
//  Lume
//
//  One modifier that tells the background content indexer someone is using the
//  app right now, so it stands aside.
//
//  `ContentIndexer` saves once per chunk, and every one of those saves forces a
//  main-context merge that re-runs every `@Query` in every mounted tab — the
//  same mechanism that used to hitch KSPlayer, which is why the indexer already
//  pauses for playback, playlist sync and CloudKit imports. On a 284k-row
//  playlist a full pass is ~4,500 of those merges spread over hours of ordinary
//  use, and a merge that lands mid-scroll breaks the scroll.
//
//  `noteUserInteraction()` is a single `Date` write and self-clearing (see
//  `ContentIndexingService.isUserBrowsing`), so a surface stamps and forgets —
//  there is no paired "done browsing" call a view could fail to make.
//

import SwiftUI

extension View {
    /// Marks a scrolling browse surface: stamps while the content is moving, and
    /// once when it appears.
    ///
    /// Attached to the scroll view rather than the screen so the stamp tracks
    /// actual interaction — a screen left open on a shelf stops stamping after a
    /// few seconds and lets indexing resume, which is the whole point of the
    /// quiet window being short.
    func browseActivity() -> some View {
        onScrollPhaseChange { _, phase in
            guard phase != .idle else { return }
            ContentIndexingService.shared.noteUserInteraction()
        }
        .onAppear { ContentIndexingService.shared.noteUserInteraction() }
    }
}
