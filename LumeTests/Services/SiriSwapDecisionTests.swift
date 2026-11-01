import Foundation
@testable import Lume
import Testing

/// What a Siri request does when it arrives while a single player is up.
@MainActor
struct SiriSwapDecisionTests {
    private func media(_ id: String) throws -> PlayableMedia {
        try PlayableMedia(
            id: id,
            url: #require(URL(string: "http://example.com/\(id).ts")),
            title: id,
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live(id)
        )
    }

    @Test func `a playable stream swaps into the open player`() throws {
        let stream = try media("l1")
        let decision = SiriSwapDecision(for: .playLive(id: "l1"), target: .play(stream), playerTakesSwap: true)

        #expect(decision == .swap(stream))
    }

    @Test func `a series waits for the player to close`() {
        let series = Series(id: "s1", seriesId: 1, name: "A Show")
        let decision = SiriSwapDecision(for: .openSeries(id: "s1"), target: .openSeries(series), playerTakesSwap: true)

        #expect(decision == .waitForPlayerToClose)
    }

    @Test func `a movie detail page waits for the player to close`() {
        let movie = Movie(id: "m1", streamId: 1, name: "A Movie")
        let decision = SiriSwapDecision(for: .openMovie(id: "m1"), target: .openMovie(movie), playerTakesSwap: true)

        #expect(decision == .waitForPlayerToClose)
    }

    @Test func `an unresolved link waits for the player to close`() {
        let decision = SiriSwapDecision(for: .playMovie(id: "gone"), target: nil, playerTakesSwap: true)

        #expect(decision == .waitForPlayerToClose)
    }

    @Test func `resume with a player up keeps that player`() {
        let decision = SiriSwapDecision(for: .resume, target: nil, playerTakesSwap: true)

        #expect(decision == .keepPlayer)
    }

    @Test func `without an open player the link routes normally`() throws {
        let stream = try media("l1")

        #expect(SiriSwapDecision(for: .playLive(id: "l1"), target: .play(stream), playerTakesSwap: false) == .route)
        #expect(SiriSwapDecision(for: .playMovie(id: "gone"), target: nil, playerTakesSwap: false) == .route)
    }
}
