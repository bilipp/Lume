import Foundation
@testable import Lume
import Testing

struct SyncProgressTests {
    @Test func `initial state`() {
        let progress = SyncProgress()
        #expect(progress.currentStep == nil)
        #expect(progress.completedSteps.isEmpty)
        #expect(progress.stepDetail.isEmpty)
        #expect(progress.stepFraction == 0)
    }

    @Test func `start step makes it current`() {
        let progress = SyncProgress()
        progress.start(.authenticating)
        #expect(progress.currentStep == .authenticating)
        #expect(progress.stepDetail.isEmpty)
        #expect(progress.stepFraction == 0)
    }

    @Test func `complete step marks it done`() {
        let progress = SyncProgress()
        progress.start(.movies)
        progress.complete(.movies)
        #expect(progress.completedSteps.contains(.movies))
        #expect(progress.currentStep == nil)
    }

    @Test func `complete unstarted step still marks it done`() {
        let progress = SyncProgress()
        progress.complete(.series)
        #expect(progress.completedSteps.contains(.series))
    }

    @Test func `state machine transitions`() {
        let progress = SyncProgress()

        #expect(progress.state(for: .authenticating) == .pending)

        progress.start(.authenticating)
        #expect(progress.state(for: .authenticating) == .active)

        progress.complete(.authenticating)
        #expect(progress.state(for: .authenticating) == .completed)
    }

    @Test func `update stores detail and fraction`() {
        let progress = SyncProgress()
        progress.start(.movies)
        progress.update(detail: "500 of 5000", fraction: 0.1)
        #expect(progress.stepDetail == "500 of 5000")
        #expect(progress.stepFraction == 0.1)
    }

    @Test func `overall fraction starts at zero`() {
        let progress = SyncProgress()
        #expect(progress.overallFraction == 0)
    }

    @Test func `overall fraction increases with completed steps`() {
        let progress = SyncProgress()
        let totalSteps = Double(progress.steps.count)

        progress.complete(.authenticating)
        #expect(progress.overallFraction == 1.0 / totalSteps)

        progress.complete(.movieCategories)
        #expect(progress.overallFraction == 2.0 / totalSteps)
    }

    @Test func `overall fraction all completed`() {
        let progress = SyncProgress()
        for step in SyncStep.allCases {
            progress.complete(step)
        }
        #expect(progress.overallFraction == 1.0)
    }

    @Test func `overall fraction with active step`() {
        let progress = SyncProgress()
        progress.complete(.authenticating)
        progress.complete(.movieCategories)
        progress.start(.seriesCategories)
        progress.update(detail: "", fraction: 0.5)

        let total = Double(progress.steps.count)
        let expected = (2.0 + 0.5) / total
        #expect(progress.overallFraction == expected)
    }

    @Test func `all steps have titles`() {
        for step in SyncStep.allCases {
            #expect(!String(localized: step.title).isEmpty)
        }
    }

    @Test func `all steps have system images`() {
        for step in SyncStep.allCases {
            #expect(!step.systemImage.isEmpty)
        }
    }

    @Test func `step order is correct`() {
        let ordered = SyncStep.allCases
        #expect(ordered[0] == .authenticating)
        #expect(ordered[1] == .movieCategories)
        #expect(ordered[2] == .seriesCategories)
        #expect(ordered[3] == .liveCategories)
        #expect(ordered[4] == .movies)
        #expect(ordered[5] == .series)
        #expect(ordered[6] == .liveStreams)
    }
}
