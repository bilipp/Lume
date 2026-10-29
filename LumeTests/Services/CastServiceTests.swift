import Foundation
@testable import Lume
import Testing

@MainActor
struct CastServiceTests {
    typealias RouteOutput = CastService.RouteOutput

    // MARK: - AirPlay route

    @Test func `no outputs means no AirPlay route`() {
        #expect(CastService.activeAirPlayName(in: []) == nil)
    }

    @Test func `non-AirPlay outputs are ignored`() {
        let outputs = [
            RouteOutput(isAirPlay: false, name: "Speaker"),
            RouteOutput(isAirPlay: false, name: "Headphones")
        ]
        #expect(CastService.activeAirPlayName(in: outputs) == nil)
    }

    @Test func `an AirPlay output reports its name`() {
        let outputs = [RouteOutput(isAirPlay: true, name: "Living Room")]
        #expect(CastService.activeAirPlayName(in: outputs) == "Living Room")
    }

    @Test func `the first AirPlay output wins among a mixed route`() {
        let outputs = [
            RouteOutput(isAirPlay: false, name: "Speaker"),
            RouteOutput(isAirPlay: true, name: "Apple TV"),
            RouteOutput(isAirPlay: true, name: "Bedroom")
        ]
        #expect(CastService.activeAirPlayName(in: outputs) == "Apple TV")
    }

    // MARK: - Route reducer

    @Test(arguments: [
        (nil, CastConnectionState.idle, nil, CastRoute.local),
        ("Apple TV", .idle, nil, .airPlay("Apple TV")),
        (nil, .connecting, "Kitchen", .connectingChromecast(deviceName: "Kitchen")),
        (nil, .connected, "Kitchen", .chromecast(deviceName: "Kitchen")),
        ("Apple TV", .connecting, "Kitchen", .connectingChromecast(deviceName: "Kitchen")),
        ("Apple TV", .connected, "Kitchen", .chromecast(deviceName: "Kitchen")),
        ("Apple TV", .connected, nil, .chromecast(deviceName: nil))
    ] as [(String?, CastConnectionState, String?, CastRoute)])
    func `a Google Cast session wins over AirPlay`(
        airPlayName: String?,
        chromecast: CastConnectionState,
        deviceName: String?,
        expected: CastRoute
    ) {
        let route = CastService.route(airPlayName: airPlayName, chromecast: chromecast, chromecastDeviceName: deviceName)
        #expect(route == expected)
    }

    @Test(arguments: [
        (CastPlaybackStatus.IdleReason.finished, CastSessionEnd.Reason.finished),
        (.stopped, .stopped),
        (.error, .error),
        (.interrupted, nil)
    ] as [(CastPlaybackStatus.IdleReason, CastSessionEnd.Reason?)])
    func `only a replaced item is not an end`(idleReason: CastPlaybackStatus.IdleReason, expected: CastSessionEnd.Reason?) {
        #expect(idleReason.sessionEndReason == expected)
    }

    // MARK: - Provider registration

    @Test func `registering a provider mirrors its state`() {
        let provider = StubCastProvider()
        provider.devices = [Self.device]
        provider.connectionState = .connected
        provider.connectedDeviceName = "Living Room TV"

        let service = CastService(castProvider: provider)

        #expect(service.devices == [Self.device])
        #expect(service.isChromecastActive)
        #expect(service.chromecastDeviceName == "Living Room TV")
        #expect(provider.eventHandler != nil)
    }

    @Test func `without a provider Chromecast stays idle`() {
        let service = CastService()

        service.startDiscovery()

        #expect(service.devices.isEmpty)
        #expect(!service.isChromecastActive)
        #expect(service.status == .idle)
    }

    @Test func `replacing a provider detaches the old one`() {
        let old = StubCastProvider()
        let service = CastService(castProvider: old)
        let new = StubCastProvider()

        service.castProvider = new

        #expect(old.eventHandler == nil)
        #expect(new.eventHandler != nil)
    }

    @Test func `provider events update the observable state`() {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)

        provider.simulateDevices([Self.device])
        #expect(service.devices == [Self.device])

        provider.simulateConnection(.connecting)
        #expect(service.route == .connectingChromecast(deviceName: "Living Room TV"))
        #expect(!service.isChromecastActive)

        provider.simulateConnection(.connected)
        #expect(service.isChromecastActive)

        provider.simulatePlaying(at: 42)
        #expect(service.status.position == 42)
        #expect(service.status.isPlaying)
    }

    @Test func `control calls reach the provider`() {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)

        service.startDiscovery()
        service.connect(to: Self.device)
        service.play()
        service.pause()
        service.seek(to: -5)
        service.setVolume(1.5)
        service.endSession(stopReceiver: true)
        service.stopDiscovery()

        #expect(provider.calls == [
            .startDiscovery, .connect("device-1"), .play, .pause, .seek(0),
            .setVolume(1), .endSession(stopReceiver: true), .stopDiscovery
        ])
    }

    // MARK: - Loading

    @Test func `a load needs a connected receiver`() async {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)

        await #expect(throws: CastError.notConnected) {
            try await service.load(Self.request)
        }
        #expect(provider.calls.isEmpty)
    }

    @Test func `an accepted load becomes the current request`() async throws {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)
        provider.simulateConnection(.connected)

        try await service.load(Self.request)

        #expect(service.currentRequest == Self.request)
        #expect(service.currentContentRef == .episode("e1"))
        #expect(provider.calls == [.load(Self.request.contentURL)])
    }

    @Test func `a rejected load leaves no current request`() async {
        let provider = StubCastProvider()
        provider.loadFailure = .loadFailed
        let service = CastService(castProvider: provider)
        provider.simulateConnection(.connected)

        await #expect(throws: CastError.loadFailed) {
            try await service.load(Self.request)
        }
        #expect(service.currentRequest == nil)
    }

    // MARK: - Session end

    @Test(arguments: [
        (CastPlaybackStatus.IdleReason.finished, CastSessionEnd.Reason.finished),
        (.stopped, .stopped),
        (.error, .error)
    ])
    func `receiver idle reports the end once`(
        idleReason: CastPlaybackStatus.IdleReason,
        expected: CastSessionEnd.Reason
    ) async throws {
        let (provider, service) = try await Self.casting()
        var ends: [CastSessionEnd] = []
        service.observeSessionEnd(owner: "test") { ends.append($0) }

        provider.simulatePlaying(at: 600, duration: 1800)
        provider.simulateIdle(idleReason)
        provider.simulateIdle(idleReason)

        #expect(ends == [CastSessionEnd(reason: expected, lastPosition: 600, duration: 1800, request: Self.request)])
        #expect(service.currentRequest == nil)
    }

    @Test func `an interrupted item does not end the cast`() async throws {
        let (provider, service) = try await Self.casting()
        var ends: [CastSessionEnd] = []
        service.observeSessionEnd(owner: "test") { ends.append($0) }

        provider.simulatePlaying(at: 30)
        provider.simulateIdle(.interrupted)

        #expect(ends.isEmpty)
        #expect(service.currentRequest == Self.request)
    }

    @Test func `a load the receiver fails before playing still ends`() async throws {
        let (provider, service) = try await Self.casting()
        var ends: [CastSessionEnd] = []
        service.observeSessionEnd(owner: "test") { ends.append($0) }

        provider.simulateIdle(.error)

        #expect(ends.map(\.reason) == [.error])
        #expect(ends.first?.lastPosition == Self.request.startTime)
    }

    @Test func `losing the session ends the media and resets state`() async throws {
        let (provider, service) = try await Self.casting()
        var ends: [CastSessionEnd] = []
        service.observeSessionEnd(owner: "test") { ends.append($0) }

        provider.simulatePlaying(at: 120)
        provider.simulateSessionEnd(.disconnected)

        #expect(ends == [CastSessionEnd(reason: .disconnected, lastPosition: 120, duration: 3600, request: Self.request)])
        #expect(!service.isChromecastActive)
        #expect(service.chromecastDeviceName == nil)
        #expect(service.currentRequest == nil)
        #expect(service.status == .idle)
    }

    @Test func `a resumed session reports its end without a request`() {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)
        var ends: [CastSessionEnd] = []
        service.observeSessionEnd(owner: "test") { ends.append($0) }
        provider.simulateConnection(.connected)

        provider.simulatePlaying(at: 75)
        provider.simulateIdle(.stopped)

        #expect(ends == [CastSessionEnd(reason: .stopped, lastPosition: 75, duration: 3600, request: nil)])
    }

    @Test func `a removed observer hears nothing`() async throws {
        let (provider, service) = try await Self.casting()
        var ends = 0
        service.observeSessionEnd(owner: "test") { _ in ends += 1 }
        service.removeSessionEndObserver(owner: "test")

        provider.simulatePlaying(at: 10)
        provider.simulateIdle(.finished)

        #expect(ends == 0)
    }

    // MARK: - Mini-controller

    @Test(arguments: [
        (CastConnectionState.connected, true, false, false, true),
        (.connected, false, true, false, true),
        (.connected, false, false, false, false),
        (.connected, true, true, true, false),
        (.connecting, true, true, false, false),
        (.idle, true, true, false, false)
    ] as [(CastConnectionState, Bool, Bool, Bool, Bool)])
    func `the mini-controller shows only while a cast plays behind the tabs`(
        connection: CastConnectionState,
        hasLoadedMedia: Bool,
        receiverHasMedia: Bool,
        playerIsVisible: Bool,
        expected: Bool
    ) {
        let visible = CastMiniControllerPolicy.isVisible(
            connection: connection,
            hasLoadedMedia: hasLoadedMedia,
            receiverHasMedia: receiverHasMedia,
            playerIsVisible: playerIsVisible
        )
        #expect(visible == expected)
    }

    @Test func `a resumed session opens the status-only remote with the receiver's metadata`() {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)
        var opened: PlayableMedia?
        let model = CastMiniControllerModel(castService: service) { opened = $0 }
        model.start()
        provider.simulateConnection(.connected)

        var status = CastPlaybackStatus.idle
        status.hasMedia = true
        status.isPlaying = true
        status.duration = 1800
        status.title = "Receiver Title"
        provider.simulateStatus(status)
        model.open()

        #expect(model.receiverHasMedia)
        #expect(model.isPlaying)
        #expect(model.item.title == "Receiver Title")
        #expect(model.showsRemote)
        #expect(opened == nil)
        model.stop()
    }

    @Test func `a stream Lume loaded reopens the full-screen player`() async throws {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)
        var opened: PlayableMedia?
        let model = CastMiniControllerModel(castService: service) { opened = $0 }
        provider.simulateConnection(.connected)
        let media = PlayableMedia(
            id: "e1", url: Self.request.contentURL, title: "Pilot", subtitle: "S1 E1", posterURL: nil,
            kind: .vod, startTime: 15, contentRef: .episode("e1"), httpHeaders: nil
        )
        try await service.load(Self.request, media: media)

        model.open()

        #expect(opened == media)
        #expect(!model.showsRemote)
    }

    @Test func `the mini-controller's controls reach the receiver`() {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)
        let model = CastMiniControllerModel(castService: service) { _ in }
        model.start()
        provider.simulateConnection(.connected)
        provider.simulatePlaying(at: 10)

        model.togglePlayback()
        model.stopCasting()

        #expect(provider.calls == [.pause, .endSession(stopReceiver: true)])
        model.stop()
    }

    // MARK: - Premium

    @Test func `the Pro features list Chromecast on iPhone and iPad`() {
        #expect(PremiumFeature.available.contains(.chromecast))
        #expect(PremiumFeature.chromecast.title.key == "premium.chromecast.title")
        #expect(PremiumFeature.chromecast.subtitle.key == "premium.chromecast.subtitle")
    }

    // MARK: - Fixtures

    private static let device = CastDevice(id: "device-1", name: "Living Room TV", modelName: "Chromecast", kind: .television)

    private static let request = CastMediaRequest(
        contentURL: URL(string: "http://example.com/series/u/p/1.mp4")!,
        contentType: "video/mp4",
        streamType: .buffered,
        title: "Pilot",
        subtitle: "S1 E1",
        posterURL: nil,
        startTime: 15,
        contentRef: .episode("e1")
    )

    private static func casting() async throws -> (StubCastProvider, CastService) {
        let provider = StubCastProvider()
        let service = CastService(castProvider: provider)
        provider.simulateConnection(.connected)
        try await service.load(request)
        return (provider, service)
    }
}
