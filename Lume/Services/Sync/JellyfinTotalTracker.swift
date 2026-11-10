//
//  JellyfinTotalTracker.swift
//  Lume
//
//  Tells a Jellyfin/Emby library with a fixed length from one whose server
//  doesn't know how long it is, so the sync's item walk knows when to stop.
//

import Foundation

/// Follows the `TotalRecordCount` a library reports page by page.
///
/// A stock server reports the library's real size on every page. A server
/// that fronts a ranked list (popular, trending, a streaming service's
/// catalogue) can instead report a rolling count: what has been read so far
/// plus one more page. Its total then moves ahead by exactly the page just
/// read, and a walk that pages until it reaches the total never does.
///
/// A library counts as open-ended only while *every* page after the first has
/// moved the total by exactly its own item count. A real library that grows
/// during a scan grows by whatever the scan found, not in step with the pages,
/// so it keeps its fixed length and is read to the end.
nonisolated struct JellyfinTotalTracker {
    /// The latest total the server reported; `Int.max` before the first page.
    private(set) var total = Int.max
    private(set) var isOpenEnded = false
    private var pages = 0

    mutating func record(_ page: JellyfinItemsResponse) {
        let next = page.totalRecordCount
        if pages > 0 {
            let movedWithPage = !page.items.isEmpty && next - total == page.items.count
            isOpenEnded = (pages == 1 || isOpenEnded) && movedWithPage
        }
        total = next
        pages += 1
    }
}
