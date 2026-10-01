import Foundation
@testable import Lume
import Testing

struct GuidePreviewPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func cell(_ id: String, from start: TimeInterval, to end: TimeInterval, gap: Bool = false) -> EPGProgramCell {
        EPGProgramCell(
            id: id,
            title: id,
            detail: "",
            start: base.addingTimeInterval(start),
            end: base.addingTimeInterval(end),
            listingID: gap ? nil : id,
            isGap: gap,
            width: 100
        )
    }

    // MARK: - Timing

    @Test func `settle and restart durations`() {
        #expect(GuidePreviewPolicy.settleDuration == .seconds(1))
        #expect(GuidePreviewPolicy.restartDelay == .milliseconds(1500))
    }

    // MARK: - step

    @Test func `the Guide opens on its first channel without waiting`() {
        #expect(GuidePreviewPolicy.step(focused: nil, current: nil, first: "a") == .start("a"))
    }

    @Test func `an empty Guide previews nothing`() {
        #expect(GuidePreviewPolicy.step(focused: nil, current: nil, first: nil) == .keep)
    }

    @Test func `focus leaving the channels keeps the last channel playing`() {
        #expect(GuidePreviewPolicy.step(focused: nil, current: "b", first: "a") == .keep)
    }

    @Test func `focusing another channel waits for focus to settle`() {
        #expect(GuidePreviewPolicy.step(focused: "b", current: "a", first: "a") == .settle("b"))
        #expect(GuidePreviewPolicy.step(focused: "b", current: nil, first: "a") == .settle("b"))
    }

    @Test func `focusing the playing channel keeps it`() {
        #expect(GuidePreviewPolicy.step(focused: "a", current: "a", first: "a") == .keep)
    }

    // MARK: - shouldPreview

    @Test func `previews when nothing blocks it`() {
        #expect(GuidePreviewPolicy.shouldPreview(suspended: false, syncing: false, failed: false))
    }

    @Test func `suspension blocks the preview`() {
        #expect(!GuidePreviewPolicy.shouldPreview(suspended: true, syncing: false, failed: false))
    }

    @Test func `a running sync blocks the preview`() {
        #expect(!GuidePreviewPolicy.shouldPreview(suspended: false, syncing: true, failed: false))
    }

    @Test func `a failed channel blocks the preview`() {
        #expect(!GuidePreviewPolicy.shouldPreview(suspended: false, syncing: false, failed: true))
    }

    // MARK: - currentProgramme

    @Test func `no cells has no current programme`() {
        #expect(GuidePreviewPolicy.currentProgramme(in: [], at: base) == nil)
    }

    @Test func `finds the programme airing now`() {
        let cells = [cell("a", from: 0, to: 1800), cell("b", from: 1800, to: 3600), cell("c", from: 3600, to: 5400)]
        #expect(GuidePreviewPolicy.currentProgramme(in: cells, at: base.addingTimeInterval(2000))?.id == "b")
    }

    @Test func `a programme is current from its start instant`() {
        let cells = [cell("a", from: 0, to: 1800), cell("b", from: 1800, to: 3600)]
        #expect(GuidePreviewPolicy.currentProgramme(in: cells, at: base.addingTimeInterval(1800))?.id == "b")
    }

    @Test func `a programme is no longer current at its end instant`() {
        let cells = [cell("a", from: 0, to: 1800)]
        #expect(GuidePreviewPolicy.currentProgramme(in: cells, at: base.addingTimeInterval(1800)) == nil)
    }

    @Test func `a gap filler is never the current programme`() {
        let cells = [cell("a", from: 0, to: 1800), cell("gap", from: 1800, to: 3600, gap: true), cell("c", from: 3600, to: 5400)]
        #expect(GuidePreviewPolicy.currentProgramme(in: cells, at: base.addingTimeInterval(2400)) == nil)
    }

    @Test func `an uncovered stretch between programmes has no current programme`() {
        let cells = [cell("a", from: 0, to: 1800), cell("c", from: 3600, to: 5400)]
        #expect(GuidePreviewPolicy.currentProgramme(in: cells, at: base.addingTimeInterval(2400)) == nil)
    }

    @Test func `a time outside every cell has no current programme`() {
        let cells = [cell("a", from: 0, to: 1800)]
        #expect(GuidePreviewPolicy.currentProgramme(in: cells, at: base.addingTimeInterval(-1)) == nil)
        #expect(GuidePreviewPolicy.currentProgramme(in: cells, at: base.addingTimeInterval(7200)) == nil)
    }

    // MARK: - supportsHandoff

    @Test(arguments: PlayerEngineKind.allCases)
    func `handoff per engine without AirPlay`(engine: PlayerEngineKind) {
        let expected = switch engine {
        case .ksPlayer, .avPlayer: true
        case .vlcKit, .lumeEngine: false
        }
        #expect(GuidePreviewPolicy.supportsHandoff(engine: engine, airPlayActive: false) == expected)
    }

    @Test(arguments: PlayerEngineKind.allCases)
    func `no handoff on any engine while AirPlay is active`(engine: PlayerEngineKind) {
        #expect(!GuidePreviewPolicy.supportsHandoff(engine: engine, airPlayActive: true))
    }
}
