import Foundation
@testable import Lume
import Testing

struct DeepLinkTests {
    @Test func `parses movie link`() throws {
        let url = try #require(URL(string: "lume://movie/603"))
        #expect(DeepLink(url: url) == .movie(tmdbId: 603))
    }

    @Test func `parses series link`() throws {
        let url = try #require(URL(string: "lume://series/1396"))
        #expect(DeepLink(url: url) == .series(tmdbId: 1396))
    }

    @Test func `scheme is case insensitive`() throws {
        let url = try #require(URL(string: "LUME://MOVIE/42"))
        #expect(DeepLink(url: url) == .movie(tmdbId: 42))
    }

    @Test func `tolerates a trailing slash`() throws {
        let url = try #require(URL(string: "lume://series/77/"))
        #expect(DeepLink(url: url) == .series(tmdbId: 77))
    }

    @Test func `parses resume link`() throws {
        let url = try #require(URL(string: "lume://resume"))
        #expect(DeepLink(url: url) == .resume)
    }

    @Test func `resume is case insensitive and ignores a path`() throws {
        let url = try #require(URL(string: "lume://RESUME/anything"))
        #expect(DeepLink(url: url) == .resume)
    }

    @Test func `parses downloads link`() throws {
        let url = try #require(URL(string: "lume://downloads"))
        #expect(DeepLink(url: url) == .downloads)
    }

    @Test func `downloads is case insensitive and ignores a path`() throws {
        let url = try #require(URL(string: "lume://Downloads/anything"))
        #expect(DeepLink(url: url) == .downloads)
    }

    @Test func `rejects a foreign scheme`() throws {
        let url = try #require(URL(string: "https://movie/603"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func `rejects an unknown kind`() throws {
        let url = try #require(URL(string: "lume://episode/603"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func `rejects a non-numeric id`() throws {
        let url = try #require(URL(string: "lume://movie/not-a-number"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func `rejects a missing id`() throws {
        let url = try #require(URL(string: "lume://movie"))
        #expect(DeepLink(url: url) == nil)
    }

    @Test func `parses cloud pairing link`() throws {
        let url = try #require(URL(string: "lume://cloud/pair?code=048213"))
        #expect(DeepLink(url: url) == .cloudPair(code: "048213"))
    }

    @Test func `cloud pairing link round-trips the pairing QR payload`() {
        let code = LumeCloudPairingCode(code: "731905", expiresAt: .distantFuture)
        #expect(DeepLink(url: code.deepLink) == .cloudPair(code: "731905"))
    }

    @Test(arguments: [
        "lume://cloud/pair",
        "lume://cloud/pair?code=12345",
        "lume://cloud/pair?code=1234567",
        "lume://cloud/pair?code=12a456",
        "lume://cloud/pair?code=%D9%A1%D9%A2%D9%A3%D9%A4%D9%A5%D9%A6",
        "lume://cloud/unpair?code=123456",
        "lume://cloud?code=123456"
    ])
    func `rejects a malformed cloud pairing link`(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(DeepLink(url: url) == nil)
    }
}

/// How a `lume://cloud/pair` link reaches the add-device sheet: queued while
/// something it can't be presented over is up, and never lost when SwiftUI
/// drops the presentation.
@MainActor
struct DeepLinkRouterCloudPairingTests {
    @Test func `a pairing link waits until the screen is clear`() throws {
        let router = DeepLinkRouter()
        router.requestCloudPairing(code: "482913")
        #expect(router.hasCloudPairing)

        #expect(router.presentPendingCloudPairing(screenIsClear: false) == false)
        #expect(router.presentedCloudPairing == nil)
        #expect(router.cloudPairingRequest?.code == "482913")

        #expect(router.presentPendingCloudPairing(screenIsClear: true))
        #expect(router.cloudPairingRequest == nil)
        #expect(try #require(router.presentedCloudPairing).code == "482913")
        #expect(router.hasCloudPairing)
    }

    @Test func `a presentation that never appears goes back to waiting`() throws {
        let router = DeepLinkRouter()
        router.requestCloudPairing(code: "120934")
        router.presentPendingCloudPairing(screenIsClear: true)

        router.requeueCloudPairingIfNotShown()
        #expect(router.presentedCloudPairing == nil)
        #expect(try #require(router.cloudPairingRequest).code == "120934")

        router.presentPendingCloudPairing(screenIsClear: true)
        router.noteCloudPairingSheetAppeared()
        router.requeueCloudPairingIfNotShown()
        #expect(router.presentedCloudPairing?.code == "120934")
        #expect(router.cloudPairingRequest == nil)
    }

    @Test func `a newer link waits for the sheet on screen and replaces a waiting one`() throws {
        let router = DeepLinkRouter()
        router.requestCloudPairing(code: "111111")
        router.presentPendingCloudPairing(screenIsClear: true)
        router.noteCloudPairingSheetAppeared()

        router.requestCloudPairing(code: "222222")
        router.requestCloudPairing(code: "333333")
        #expect(router.presentPendingCloudPairing(screenIsClear: true) == false)
        #expect(router.presentedCloudPairing?.code == "111111")

        router.presentedCloudPairing = nil
        #expect(router.presentPendingCloudPairing(screenIsClear: true))
        #expect(try #require(router.presentedCloudPairing).code == "333333")
        #expect(router.cloudPairingSheetAppeared == false)
    }

    @Test func `a dropped presentation does not override a newer link`() throws {
        let router = DeepLinkRouter()
        router.requestCloudPairing(code: "555555")
        router.presentPendingCloudPairing(screenIsClear: true)
        router.requestCloudPairing(code: "666666")

        router.requeueCloudPairingIfNotShown()
        #expect(router.presentedCloudPairing == nil)
        #expect(try #require(router.cloudPairingRequest).code == "666666")
    }

    @Test func `dismissing the sheet clears the pairing`() {
        let router = DeepLinkRouter()
        router.requestCloudPairing(code: "908172")
        router.presentPendingCloudPairing(screenIsClear: true)
        router.noteCloudPairingSheetAppeared()

        router.presentedCloudPairing = nil
        #expect(router.hasCloudPairing == false)
    }
}

/// The in-memory slot a Siri request waits in while the launch gate, a PIN pad
/// or the paywall is up.
@MainActor
struct IntentRouterTests {
    @Test func `an enqueued request is consumed once the screen is clear`() {
        let router = IntentRouter()
        router.enqueue(.playLive(id: "p-l1"), startedBySiri: true)
        #expect(router.hasPending)

        let outcome = router.consumePending(screenIsClear: true, isPremium: true)
        #expect(outcome == .play(PendingIntent(link: .playLive(id: "p-l1"), startedBySiri: true)))
        #expect(router.hasPending == false)
        #expect(router.consumePending(screenIsClear: true, isPremium: true) == nil)
    }

    @Test func `a newer request overwrites one still waiting`() {
        let router = IntentRouter()
        router.enqueue(.playMovie(id: "p-m1"), startedBySiri: true)
        router.enqueue(.resume, startedBySiri: false)

        #expect(router.consumePending(screenIsClear: true, isPremium: true)
            == .play(PendingIntent(link: .resume, startedBySiri: false)))
    }

    @Test func `a request is kept while the screen is blocked`() {
        let router = IntentRouter()
        router.enqueue(.playMovie(id: "p-m1"), startedBySiri: true)

        #expect(router.consumePending(screenIsClear: false, isPremium: true) == nil)
        #expect(router.pending?.link == .playMovie(id: "p-m1"))
        #expect(router.consumePending(screenIsClear: true, isPremium: true) != nil)
    }

    @Test func `without Pro the paywall shows once and the request is kept for an upgrade`() {
        let router = IntentRouter()
        router.enqueue(.playMovie(id: "p-m1"), startedBySiri: true)

        #expect(router.consumePending(screenIsClear: true, isPremium: false) == .showPaywall)
        #expect(router.consumePending(screenIsClear: true, isPremium: false) == nil)
        #expect(router.pending?.link == .playMovie(id: "p-m1"))

        router.paywallDismissed(isPremium: true)
        #expect(router.consumePending(screenIsClear: true, isPremium: true)
            == .play(PendingIntent(link: .playMovie(id: "p-m1"), startedBySiri: true)))
    }

    @Test func `closing the paywall without upgrading drops the request`() {
        let router = IntentRouter()
        router.enqueue(.playMovie(id: "p-m1"), startedBySiri: true)
        _ = router.consumePending(screenIsClear: true, isPremium: false)

        router.paywallDismissed(isPremium: false)
        #expect(router.hasPending == false)
    }

    @Test func `a new request behind the paywall offers the paywall again`() {
        let router = IntentRouter()
        router.enqueue(.playMovie(id: "p-m1"), startedBySiri: true)
        _ = router.consumePending(screenIsClear: true, isPremium: false)

        router.enqueue(.playLive(id: "p-l1"), startedBySiri: true)
        #expect(router.consumePending(screenIsClear: true, isPremium: false) == .showPaywall)
        #expect(router.pending?.link == .playLive(id: "p-l1"))
    }
}
