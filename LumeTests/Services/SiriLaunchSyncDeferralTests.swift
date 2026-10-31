import Foundation
@testable import Lume
import Testing

/// The launch auto-sync held for a stream Siri asked for on a cold launch.
@MainActor
struct SiriLaunchSyncDeferralTests {
    private let siriRequest = PendingIntent(link: .playLive(id: "p-l1"), startedBySiri: true)

    @Test func `defers only a Siri stream on a cold launch`() {
        #expect(SiriLaunchSyncDeferral.shouldDefer(startedBySiri: true, coldLaunch: true, playbackActive: true))
        #expect(!SiriLaunchSyncDeferral.shouldDefer(startedBySiri: false, coldLaunch: true, playbackActive: true))
        #expect(!SiriLaunchSyncDeferral.shouldDefer(startedBySiri: true, coldLaunch: false, playbackActive: true))
        #expect(!SiriLaunchSyncDeferral.shouldDefer(startedBySiri: true, coldLaunch: true, playbackActive: false))
    }

    @Test func `the launch gate holds the sync while a Siri request waits`() {
        let deferral = SiriLaunchSyncDeferral()
        #expect(deferral.holdsAutoSync(pending: siriRequest, playerIsVisible: false))
        #expect(deferral.phase == .awaitingPlayback)
        #expect(deferral.holdsAutoSync(pending: nil, playerIsVisible: false))
    }

    @Test func `a launch without a Siri request syncs as before`() {
        let deferral = SiriLaunchSyncDeferral()
        #expect(!deferral.holdsAutoSync(pending: nil, playerIsVisible: false))
        #expect(deferral.phase == .none)
    }

    @Test func `a Siri request after the launch pass is not a cold launch`() {
        let deferral = SiriLaunchSyncDeferral()
        #expect(!deferral.holdsAutoSync(pending: nil, playerIsVisible: false))
        #expect(!deferral.holdsAutoSync(pending: siriRequest, playerIsVisible: false))
        #expect(deferral.phase == .none)
    }

    @Test func `the sync resumes once the Siri player closes`() {
        let deferral = SiriLaunchSyncDeferral()
        _ = deferral.holdsAutoSync(pending: siriRequest, playerIsVisible: false)

        #expect(!deferral.update(requestPending: true, playerIsVisible: false))
        #expect(deferral.phase == .awaitingPlayback)
        #expect(!deferral.update(requestPending: false, playerIsVisible: true))
        #expect(deferral.phase == .playing)
        #expect(deferral.holdsAutoSync(pending: nil, playerIsVisible: true))

        #expect(deferral.update(requestPending: false, playerIsVisible: false))
        #expect(deferral.phase == .none)
        #expect(!deferral.holdsAutoSync(pending: nil, playerIsVisible: false))
    }

    @Test func `the sync resumes when the request never plays`() {
        let deferral = SiriLaunchSyncDeferral()
        _ = deferral.holdsAutoSync(pending: siriRequest, playerIsVisible: false)

        #expect(deferral.update(requestPending: false, playerIsVisible: false))
        #expect(deferral.phase == .none)
    }

    @Test func `nothing resumes without a deferral`() {
        let deferral = SiriLaunchSyncDeferral()
        #expect(!deferral.update(requestPending: false, playerIsVisible: false))
    }

    @Test func `a Siri launch is queued before the app comes forward`() async throws {
        let router = IntentRouter()
        let deferral = SiriLaunchSyncDeferral()
        var heldAtForeground: Bool?

        try await IntentLaunch.open(
            .playLive(id: "p-l1"),
            path: .continueInForeground,
            router: router,
            foreground: { heldAtForeground = deferral.holdsAutoSync(pending: router.pending, playerIsVisible: false) },
            refusal: CancellationError()
        )

        #expect(heldAtForeground == true)
        #expect(deferral.phase == .awaitingPlayback)
        #expect(router.pending == siriRequest)
    }

    @Test func `an older OS launch is queued before the app comes forward`() async throws {
        let router = IntentRouter()
        let deferral = SiriLaunchSyncDeferral()
        var pendingAtForeground: PendingIntent?
        var heldAtForeground: Bool?

        try await IntentLaunch.queueThenForeground(.playLive(id: "p-l1"), router: router) {
            pendingAtForeground = router.pending
            heldAtForeground = deferral.holdsAutoSync(pending: router.pending, playerIsVisible: false)
        }

        #expect(pendingAtForeground == siriRequest)
        #expect(heldAtForeground == true)
    }

    @Test func `an older OS launch that can't come forward takes the request back`() async {
        struct Denied: Error {}
        let router = IntentRouter()

        await #expect(throws: Denied.self) {
            try await IntentLaunch.queueThenForeground(.playLive(id: "p-l1"), router: router) {
                throw Denied()
            }
        }

        #expect(!router.hasPending)
    }

    @Test func `an older OS launch keeps a newer request when it can't come forward`() async {
        struct Denied: Error {}
        let router = IntentRouter()
        let newer = PendingIntent(link: .playMovie(id: "p-m2"), startedBySiri: true)

        await #expect(throws: Denied.self) {
            try await IntentLaunch.queueThenForeground(.playLive(id: "p-l1"), router: router) {
                router.enqueue(newer.link, startedBySiri: true)
                throw Denied()
            }
        }

        #expect(router.pending == newer)
    }

    @Test func `an older OS launch that comes forward leaves the request pending`() async throws {
        let router = IntentRouter()

        try await IntentLaunch.queueThenForeground(.playLive(id: "p-l1"), router: router) {}

        #expect(router.pending == siriRequest)
    }
}

/// How a play intent gets Lume forward without leaving a request that plays
/// unasked later.
@MainActor
struct IntentLaunchTests {
    private struct Denied: Error {}

    @Test func `picks the path from the current mode`() {
        #expect(IntentLaunch.path(isForeground: true, canContinueInForeground: false) == .alreadyForeground)
        #expect(IntentLaunch.path(isForeground: true, canContinueInForeground: true) == .alreadyForeground)
        #expect(IntentLaunch.path(isForeground: false, canContinueInForeground: true) == .continueInForeground)
        #expect(IntentLaunch.path(isForeground: false, canContinueInForeground: false) == .refuse)
    }

    @Test func `a launch that can't come forward leaves nothing pending`() async {
        let router = IntentRouter()
        var foregrounded = false

        await #expect(throws: Denied.self) {
            try await IntentLaunch.open(
                .playMovie(id: "p-m1"),
                path: .refuse,
                router: router,
                foreground: { foregrounded = true },
                refusal: Denied()
            )
        }

        #expect(!foregrounded)
        #expect(!router.hasPending)
    }

    @Test func `a denied foregrounding takes the request back`() async {
        let router = IntentRouter()

        await #expect(throws: Denied.self) {
            try await IntentLaunch.open(
                .playMovie(id: "p-m1"),
                path: .continueInForeground,
                router: router,
                foreground: { throw Denied() },
                refusal: CancellationError()
            )
        }

        #expect(!router.hasPending)
    }

    @Test func `a denied foregrounding keeps a newer request`() async {
        let router = IntentRouter()

        await #expect(throws: Denied.self) {
            try await IntentLaunch.open(
                .playMovie(id: "p-m1"),
                path: .continueInForeground,
                router: router,
                foreground: {
                    router.enqueue(.playLive(id: "p-l2"), startedBySiri: true)
                    throw Denied()
                },
                refusal: CancellationError()
            )
        }

        #expect(router.pending == PendingIntent(link: .playLive(id: "p-l2"), startedBySiri: true))
    }

    @Test func `an app already in front queues without foregrounding`() async throws {
        let router = IntentRouter()
        var foregrounded = false

        try await IntentLaunch.open(
            .playMovie(id: "p-m1"),
            path: .alreadyForeground,
            router: router,
            foreground: { foregrounded = true },
            refusal: Denied()
        )

        #expect(!foregrounded)
        #expect(router.pending == PendingIntent(link: .playMovie(id: "p-m1"), startedBySiri: true))
    }
}
