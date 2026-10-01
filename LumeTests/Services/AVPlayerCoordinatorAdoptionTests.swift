import AVFoundation
import Foundation
@testable import Lume
import Testing

@MainActor
struct AVPlayerCoordinatorAdoptionTests {
    private func media(_ id: String, startTime: TimeInterval = 0) -> PlayableMedia {
        PlayableMedia(
            id: id,
            url: URL(string: "http://127.0.0.1:9/live/\(id).m3u8")!,
            title: id,
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: startTime,
            contentRef: .live(id)
        )
    }

    /// The loads below would otherwise record QoE sessions into the shared
    /// store the app reads.
    private func withQoESuspended(_ body: (AVPlayerCoordinator) -> Void) {
        PlaybackQoE.shared.suspend(for: "avplayer-adoption-tests")
        defer { PlaybackQoE.shared.resume(for: "avplayer-adoption-tests") }
        let coordinator = AVPlayerCoordinator(isEmbedded: true)
        defer { coordinator.tearDown() }
        body(coordinator)
    }

    @Test func `an adopted coordinator keeps the item it already plays`() {
        withQoESuspended { coordinator in
            coordinator.configure(media: media("a"))
            let loaded = coordinator.player.currentItem
            #expect(loaded != nil)
            #expect(coordinator.keepLoadedItem(as: media("a")))
            #expect(coordinator.player.currentItem === loaded)
        }
    }

    @Test func `a coordinator that was not adopted reloads the same stream`() {
        withQoESuspended { coordinator in
            coordinator.configure(media: media("a"))
            let first = coordinator.player.currentItem
            coordinator.reload(media: media("a"))
            #expect(coordinator.player.currentItem !== first)
        }
    }

    @Test func `another stream, another start time or Try Again replaces the item`() {
        withQoESuspended { coordinator in
            coordinator.configure(media: media("a"))
            let first = coordinator.player.currentItem
            #expect(!coordinator.keepLoadedItem(as: media("b")))
            #expect(!coordinator.keepLoadedItem(as: media("a", startTime: 30)))
            #expect(coordinator.player.currentItem === first)
            coordinator.retryAfterFailure()
            #expect(coordinator.player.currentItem !== first)
        }
    }

    @Test func `a torn-down coordinator loads again`() {
        withQoESuspended { coordinator in
            coordinator.configure(media: media("a"))
            coordinator.tearDown()
            #expect(!coordinator.keepLoadedItem(as: media("a")))
            coordinator.configure(media: media("a"))
            #expect(coordinator.player.currentItem != nil)
        }
    }

    @Test func `attaching a new layer takes the player off the old one`() {
        let coordinator = AVPlayerCoordinator(isEmbedded: true)
        let previewLayer = AVPlayerLayer()
        coordinator.attach(layer: previewLayer)
        #expect(previewLayer.player === coordinator.player)
        coordinator.isEmbedded = false
        coordinator.isAdoptedFromPreview = true
        let fullScreenLayer = AVPlayerLayer()
        coordinator.attach(layer: fullScreenLayer)
        #expect(previewLayer.player == nil)
        #expect(fullScreenLayer.player === coordinator.player)
        #expect(coordinator.player.allowsExternalPlayback)
    }
}
