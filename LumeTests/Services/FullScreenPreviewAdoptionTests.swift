import Foundation
import KSPlayer
@testable import Lume
import Testing

@MainActor
struct FullScreenPreviewAdoptionTests {
    private func media(_ id: String, host: String = "example.com") -> PlayableMedia {
        PlayableMedia(
            id: id,
            url: URL(string: "http://\(host)/live/\(id).ts")!,
            title: id,
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live(id)
        )
    }

    private let priority: [PlayerEngineKind] = [.vlcKit, .ksPlayer, .avPlayer, .lumeEngine]

    private func startedHandle(
        _ coordinator: KSVideoPlayer.Coordinator? = nil,
        resolved: PlayableMedia? = nil
    ) -> PreviewPlayerHandle {
        let handle = PreviewPlayerHandle()
        handle.register(
            media: media("a"),
            resolved: resolved ?? media("a"),
            coordinator: .ks(coordinator ?? KSVideoPlayer.Coordinator())
        )
        handle.markStarted()
        handle.handOffToFullScreen()
        return handle
    }

    private func adoption(
        of handle: PreviewPlayerHandle?,
        for selected: String = "a",
        priority: [PlayerEngineKind]? = nil,
        airPlayActive: Bool = false
    ) -> FullScreenPlayerView.PreviewAdoption? {
        FullScreenPlayerView.previewAdoption(
            of: handle, for: media(selected), enginePriority: priority ?? self.priority, airPlayActive: airPlayActive
        )
    }

    @Test func `adopts a started KSPlayer preview at KSPlayer's priority index`() {
        let coordinator = KSVideoPlayer.Coordinator()
        let resolved = media("a", host: "resolved.example.com")
        let result = adoption(of: startedHandle(coordinator, resolved: resolved))
        #expect(result?.engineAttempt == 1)
        #expect(result?.coordinator.ksCoordinator === coordinator)
        #expect(result?.resolvedMedia == resolved)
    }

    @Test func `refuses a handle the Guide has not claimed`() {
        let handle = PreviewPlayerHandle()
        handle.register(media: media("a"), resolved: nil, coordinator: .ks(KSVideoPlayer.Coordinator()))
        handle.markStarted()
        #expect(adoption(of: handle) == nil)
    }

    @Test func `refuses without a handle, for another channel or under AirPlay`() {
        #expect(adoption(of: nil) == nil)
        #expect(adoption(of: startedHandle(), for: "b") == nil)
        #expect(adoption(of: startedHandle(), airPlayActive: true) == nil)
    }

    @Test func `refuses a preview that has not started or was released`() {
        let unstarted = PreviewPlayerHandle()
        unstarted.register(media: media("a"), resolved: nil, coordinator: .ks(KSVideoPlayer.Coordinator()))
        unstarted.handOffToFullScreen()
        #expect(adoption(of: unstarted) == nil)

        let released = startedHandle()
        released.release()
        #expect(adoption(of: released) == nil)
    }

    @Test func `adopts a started AVPlayer preview at AVPlayer's priority index`() {
        let coordinator = AVPlayerCoordinator(isEmbedded: true)
        let resolved = media("a", host: "resolved.example.com")
        let handle = PreviewPlayerHandle()
        handle.register(media: media("a"), resolved: resolved, coordinator: .av(coordinator))
        handle.markStarted()
        handle.handOffToFullScreen()
        let result = adoption(of: handle)
        #expect(result?.engineAttempt == 2)
        #expect(result?.coordinator.avCoordinator === coordinator)
        #expect(result?.coordinator.ksCoordinator == nil)
        #expect(result?.resolvedMedia == resolved)
        #expect(adoption(of: handle, airPlayActive: true) == nil)
        #expect(adoption(of: handle, priority: [.ksPlayer, .vlcKit]) == nil)
    }

    @Test func `refuses when KSPlayer is missing from the priority list`() {
        #expect(adoption(of: startedHandle(), priority: [.vlcKit, .avPlayer]) == nil)
    }

    @Test func `hand-off never reclaims a released handle`() {
        let handle = startedHandle()
        handle.release()
        handle.handOffToFullScreen()
        #expect(handle.owner == .released)
    }
}
