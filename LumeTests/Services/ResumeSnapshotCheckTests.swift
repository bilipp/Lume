//
//  ResumeSnapshotCheckTests.swift
//  LumeTests
//
//  The re-check a drained Siri resume runs against the profile active now:
//  the snapshot's content maps to the catalog link of its kind, restricted
//  titles and recordings are refused for a child, and an allowed title plays.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct ResumeSnapshotCheckTests {
    private struct Catalog {
        let container: ModelContainer
        let prefix: String
        let restrictedCategoryID: String
    }

    private func seed() throws -> Catalog {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Test", serverURL: "http://example.com", username: "u", password: "p")
        context.insert(playlist)
        let prefix = playlist.id.uuidString
        let restricted = Lume.Category(apiId: "9", name: "Adults", parentId: 0, type: .vod, playlist: playlist)
        restricted.isRestricted = true
        context.insert(restricted)

        context.insert(Movie(id: "\(prefix)-m1", streamId: 1, name: "Family Movie"))
        context.insert(Movie(id: "\(prefix)-m2", streamId: 2, name: "Adult Movie", categoryId: restricted.id))
        let series = Series(id: "\(prefix)-s1", seriesId: 10, name: "Show")
        context.insert(series)
        context.insert(Episode(
            id: "\(prefix)-s1-1-1", episodeId: "e1", title: "Pilot", containerExtension: "mp4",
            seasonNum: 1, episodeNum: 1, series: series
        ))
        context.insert(LiveStream(id: "\(prefix)-l1", streamId: 100, name: "News"))
        try context.save()
        return Catalog(container: container, prefix: prefix, restrictedCategoryID: restricted.id)
    }

    private func media(_ ref: PlayableMedia.ContentRef) -> PlayableMedia {
        PlayableMedia(
            id: "snapshot",
            url: URL(string: "http://example.com/stream")!,
            title: "Snapshot",
            subtitle: nil,
            posterURL: nil,
            kind: { if case .live = ref { .live } else { .vod } }(),
            startTime: 0,
            contentRef: ref
        )
    }

    private func allows(
        _ ref: PlayableMedia.ContentRef,
        _ catalog: Catalog,
        child: Bool = false
    ) -> Bool {
        let context = catalog.container.mainContext
        return ResumeSnapshotCheck.allows(
            media(ref),
            in: context,
            restriction: ContentRestriction.fromCatalog(context, isChildProfile: child),
            isPremium: true
        )
    }

    // MARK: - Mapping

    @Test func `each catalog kind maps to the play link of its kind`() {
        #expect(ResumeSnapshotCheck.catalogLink(for: .movie("m")) == .playMovie(id: "m"))
        #expect(ResumeSnapshotCheck.catalogLink(for: .episode("e")) == .playEpisode(id: "e"))
        #expect(ResumeSnapshotCheck.catalogLink(for: .live("l")) == .playLive(id: "l"))
    }

    @Test func `a recording has no catalog link`() {
        #expect(ResumeSnapshotCheck.catalogLink(for: .recording("r")) == nil)
    }

    // MARK: - Re-check

    @Test func `an allowed title of every kind is reopened`() throws {
        let catalog = try seed()
        #expect(allows(.movie("\(catalog.prefix)-m1"), catalog))
        #expect(allows(.episode("\(catalog.prefix)-s1-1-1"), catalog))
        #expect(allows(.live("\(catalog.prefix)-l1"), catalog))
        #expect(allows(.movie("\(catalog.prefix)-m1"), catalog, child: true))
    }

    @Test func `restricted content is refused for a child profile only`() throws {
        let catalog = try seed()
        let restricted = PlayableMedia.ContentRef.movie("\(catalog.prefix)-m2")
        #expect(allows(restricted, catalog))
        #expect(!allows(restricted, catalog, child: true))
    }

    @Test func `a recording is refused for a child profile only`() throws {
        let catalog = try seed()
        #expect(allows(.recording("r1"), catalog))
        #expect(!allows(.recording("r1"), catalog, child: true))
    }

    @Test func `a title gone from the catalog is refused`() throws {
        let catalog = try seed()
        #expect(!allows(.movie("\(catalog.prefix)-missing"), catalog))
    }
}
