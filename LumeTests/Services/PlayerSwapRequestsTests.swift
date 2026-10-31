import Foundation
@testable import Lume
import Testing

/// The slot a Siri request lands in while a full-screen player is already up.
@MainActor
struct PlayerSwapRequestsTests {
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

    @Test func `an accepted request is consumed exactly once`() throws {
        let requests = PlayerSwapRequests()
        try requests.request(media("l1"))
        var applied: [String] = []

        #expect(requests.deliver { applied.append($0.id); return true })
        #expect(requests.pending == nil)
        #expect(!requests.deliver { applied.append($0.id); return true })
        #expect(applied == ["l1"])
    }

    @Test func `a request during the swap cooldown is kept and applied once accepted`() throws {
        let requests = PlayerSwapRequests()
        let swapper = PlayerMediaSwapper()
        let start = Date()
        #expect(swapper.swap(at: start) {})
        try requests.request(media("l1"))
        var applied: [String] = []

        let duringCooldown = requests.deliver { media in
            swapper.swap(at: start.addingTimeInterval(PlayerMediaSwapper.cooldown / 2)) { applied.append(media.id) }
        }
        #expect(!duringCooldown)
        #expect(requests.pending?.media.id == "l1")
        #expect(applied.isEmpty)

        let afterCooldown = requests.deliver { media in
            // A hair past the cooldown: `start + cooldown` reads back as just under it.
            swapper.swap(at: start.addingTimeInterval(PlayerMediaSwapper.cooldown + 0.01)) { applied.append(media.id) }
        }
        #expect(afterCooldown)
        #expect(requests.pending == nil)
        #expect(applied == ["l1"])
    }

    @Test func `a newer request replaces one not yet taken`() throws {
        let requests = PlayerSwapRequests()
        try requests.request(media("l1"))
        try requests.request(media("l2"))
        var applied: [String] = []

        requests.deliver { applied.append($0.id); return true }
        #expect(applied == ["l2"])
    }

    @Test func `asking for the same stream again is still a change`() throws {
        let requests = PlayerSwapRequests()
        try requests.request(media("l1"))
        let first = requests.pending
        try requests.request(media("l1"))

        #expect(requests.pending != first)
    }
}
