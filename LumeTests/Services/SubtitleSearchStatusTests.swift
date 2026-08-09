//
//  SubtitleSearchStatusTests.swift
//  LumeTests
//
//  The results area shows one of five states, and both layouts (the iOS `List`
//  and the tvOS ten-foot column) switch on the same value — so the precedence
//  between them is worth pinning down here rather than in two view bodies.
//

@testable import Lume
import Testing

struct SubtitleSearchStatusTests {
    /// Mirrors `SubtitleSearchView.status`. Kept in step by the tests below —
    /// the view's own property can't be read without mounting the view.
    private func status(
        isSearching: Bool = false,
        errorMessage: String? = nil,
        query: OpenSubtitlesQuery? = OpenSubtitlesQuery(tmdbId: 550),
        results: [OnlineSubtitle] = []
    ) -> SubtitleSearchStatus {
        if isSearching { return .searching }
        if let errorMessage { return .failed(errorMessage) }
        if query == nil { return .unsupported }
        return results.isEmpty ? .empty : .results
    }

    private var sample: OnlineSubtitle {
        OnlineSubtitle(
            id: "1",
            fileID: 2,
            languageCode: "en",
            releaseName: "Some.Release",
            downloadCount: 10,
            isHearingImpaired: false,
            isMachineTranslated: false,
            isFromTrusted: false,
            rating: 0
        )
    }

    @Test func `an in-flight search outranks everything else`() {
        #expect(status(isSearching: true, errorMessage: "boom", results: [sample]) == .searching)
    }

    @Test func `an error outranks a stale result set`() {
        #expect(status(errorMessage: "boom", results: [sample]) == .failed("boom"))
    }

    /// A live channel has nothing to search on, which is a different message
    /// from "searched and found nothing".
    @Test func `no query reads as unsupported, not empty`() {
        #expect(status(query: nil) == .unsupported)
    }

    @Test func `a finished search with no hits is empty`() {
        #expect(status() == .empty)
    }

    @Test func `hits win once everything else is clear`() {
        #expect(status(results: [sample]) == .results)
    }

    // MARK: - Badges

    @Test func `badges surface only the flags that are set`() {
        var subtitle = sample
        #expect(subtitle.badges.isEmpty)

        subtitle = OnlineSubtitle(
            id: "1", fileID: 2, languageCode: "en", releaseName: "", downloadCount: 0,
            isHearingImpaired: true, isMachineTranslated: true, isFromTrusted: true, rating: 0
        )
        #expect(subtitle.badges.map(\.id) == ["cc", "trusted", "machine"])
    }
}
