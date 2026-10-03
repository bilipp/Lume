import Foundation
import KSPlayer
@testable import Lume
import Testing

@MainActor
struct PreviewPlayerHandleTests {
    private func media(_ id: String) -> PlayableMedia {
        PlayableMedia(
            id: id,
            url: URL(string: "http://example.com/live/\(id).ts")!,
            title: id,
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live(id)
        )
    }

    private func canAdopt(
        engine: PlayerEngineKind? = .ksPlayer,
        hasStarted: Bool = true,
        previewMediaID: String? = "a",
        selectedMediaID: String = "a",
        airPlayActive: Bool = false
    ) -> Bool {
        PreviewPlayerHandle.canAdopt(
            engine: engine,
            hasStarted: hasStarted,
            previewMediaID: previewMediaID,
            selectedMediaID: selectedMediaID,
            airPlayActive: airPlayActive
        )
    }

    // MARK: - canAdopt

    @Test func `adopts a started preview of the selected channel`() {
        #expect(canAdopt())
    }

    @Test func `refuses before the first frame`() {
        #expect(!canAdopt(hasStarted: false))
    }

    @Test func `refuses without a registered engine`() {
        #expect(!canAdopt(engine: nil))
    }

    @Test func `refuses a different channel`() {
        #expect(!canAdopt(selectedMediaID: "b"))
        #expect(!canAdopt(previewMediaID: nil))
    }

    @Test(arguments: PlayerEngineKind.allCases)
    func `follows engine handoff support`(engine: PlayerEngineKind) {
        let supported = engine == .ksPlayer || engine == .avPlayer
        #expect(canAdopt(engine: engine) == supported)
        #expect(!canAdopt(engine: engine, airPlayActive: true))
    }

    // MARK: - Lifecycle

    @Test func `register then markStarted makes the handle adoptable`() {
        let handle = PreviewPlayerHandle()
        handle.register(media: media("a"), resolved: media("a"), coordinator: .av(AVPlayerCoordinator()))
        #expect(!handle.canAdopt(media("a"), airPlayActive: false))
        handle.markStarted()
        #expect(handle.canAdopt(media("a"), airPlayActive: false))
        #expect(!handle.canAdopt(media("b"), airPlayActive: false))
    }

    @Test func `refuses once the session is no longer the preview's`() {
        let handle = PreviewPlayerHandle()
        handle.register(media: media("a"), resolved: nil, coordinator: .ks(KSVideoPlayer.Coordinator()))
        handle.markStarted()
        handle.handOffToFullScreen()
        #expect(!handle.canAdopt(media("a"), airPlayActive: false))
        handle.release()
        #expect(!handle.canAdopt(media("a"), airPlayActive: false))
    }

    @Test func `register resets started and reclaims a released handle`() {
        let handle = PreviewPlayerHandle()
        handle.register(media: media("a"), resolved: nil, coordinator: .ks(KSVideoPlayer.Coordinator()))
        handle.markStarted()
        handle.release()
        #expect(handle.owner == .released)
        #expect(handle.coordinator == nil)
        #expect(!handle.hasStarted)

        handle.register(media: media("b"), resolved: nil, coordinator: .ks(KSVideoPlayer.Coordinator()))
        #expect(handle.owner == .preview)
        #expect(handle.media?.id == "b")
        #expect(!handle.hasStarted)
    }

    @Test func `register is ignored while full screen owns the session`() {
        let handle = PreviewPlayerHandle()
        let adopted = KSVideoPlayer.Coordinator()
        handle.register(media: media("a"), resolved: nil, coordinator: .ks(adopted))
        handle.owner = .fullScreen
        handle.register(media: media("b"), resolved: nil, coordinator: .av(AVPlayerCoordinator()))
        #expect(handle.media?.id == "a")
        #expect(handle.coordinator?.engine == .ksPlayer)
        #expect(handle.coordinator?.isSame(as: .ks(adopted)) == true)
    }

    @Test func `markStarted is ignored unless the preview owns the session`() {
        let handle = PreviewPlayerHandle()
        handle.register(media: media("a"), resolved: nil, coordinator: .ks(KSVideoPlayer.Coordinator()))
        handle.release()
        handle.markStarted()
        #expect(!handle.hasStarted)
    }

    @Test func `unregister clears only the tile's own registration`() {
        let handle = PreviewPlayerHandle()
        let outgoing = KSVideoPlayer.Coordinator()
        let incoming = KSVideoPlayer.Coordinator()
        handle.register(media: media("a"), resolved: nil, coordinator: .ks(outgoing))
        handle.register(media: media("b"), resolved: nil, coordinator: .ks(incoming))

        handle.unregister(.ks(outgoing))
        #expect(handle.media?.id == "b")
        #expect(handle.coordinator?.isSame(as: .ks(incoming)) == true)

        handle.unregister(.ks(incoming))
        #expect(handle.coordinator == nil)
        #expect(handle.media == nil)
    }

    @Test func `unregister leaves an adopted session alone`() {
        let handle = PreviewPlayerHandle()
        let adopted = AVPlayerCoordinator()
        handle.register(media: media("a"), resolved: nil, coordinator: .av(adopted))
        handle.owner = .fullScreen
        handle.unregister(.av(adopted))
        #expect(handle.coordinator?.isSame(as: .av(adopted)) == true)
    }

    @Test func `stopPreview releases a preview session so it can't be adopted`() {
        let handle = PreviewPlayerHandle()
        handle.register(media: media("a"), resolved: nil, coordinator: .av(AVPlayerCoordinator()))
        handle.markStarted()
        handle.stopPreview()
        #expect(handle.owner == .released)
        #expect(handle.coordinator == nil)
        #expect(!handle.canAdopt(media("a"), airPlayActive: false))
    }

    @Test func `stopPreview on an empty handle only releases it`() {
        let handle = PreviewPlayerHandle()
        handle.stopPreview()
        #expect(handle.owner == .released)
        handle.register(media: media("a"), resolved: nil, coordinator: .ks(KSVideoPlayer.Coordinator()))
        #expect(handle.owner == .preview)
    }

    @Test func `coordinators of different engines are never the same`() {
        let ksPlayer = PreviewPlayerHandle.EngineCoordinator.ks(KSVideoPlayer.Coordinator())
        let avPlayer = PreviewPlayerHandle.EngineCoordinator.av(AVPlayerCoordinator())
        #expect(!ksPlayer.isSame(as: avPlayer))
        #expect(ksPlayer.isSame(as: ksPlayer))
    }
}
