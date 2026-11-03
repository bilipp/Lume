//
//  HueSyncControllerTests.swift
//  LumeTests
//
//  `HueSyncController` against a stubbed bridge (`StubURLProtocol`, one host
//  per test) and `StubHueStreamTransport`, with ticks driven by hand.
//

import Foundation
@testable import Lume
import Synchronization
import Testing

@MainActor
struct HueSyncControllerTests {
    private static let areaID = "8d199a37-5ce4-4aae-a60e-db5d0aa27df3"
    private static let stripID = "6a1f0c2d-0000-4000-8000-000000000001"
    private static let playID = "6a1f0c2d-0000-4000-8000-000000000002"

    private final class FakeFrameSource: HueFrameSource {
        var sample: HueFrameSample = .noFrame
        private(set) var detachCount = 0

        func latestFrame() -> HueFrameSample {
            sample
        }

        func detach() {
            detachCount += 1
        }
    }

    /// Bridge answers per method and path; a light `PUT` (the restore)
    /// answers with `lightPutStatus`.
    private struct BridgeConfig {
        var areaBody: String
        var startBody: String
        var startStatus = 200
        var lightPutStatus = 200
    }

    private final class Bridge: Sendable {
        let host = "hue-\(UUID().uuidString.lowercased()).test"
        let config: Mutex<BridgeConfig>

        init() throws {
            let lights = try hueFixture("hue-lights.json")
            config = try Mutex(BridgeConfig(
                areaBody: hueFixture("hue-entertainment-configurations.json"),
                startBody: hueFixture("hue-put-ok.json")
            ))
            let services = try hueFixture("hue-entertainment-services.json")
            let putOK = try hueFixture("hue-put-ok.json")
            StubURLProtocol.register(host: host) { [weak self] request in
                guard let self else { return .init(status: 500) }
                let path = request.url?.path(percentEncoded: false) ?? ""
                let method = request.httpMethod ?? "GET"
                let current = config.withLock { $0 }
                switch (method, path) {
                case ("GET", "/clip/v2/resource/entertainment_configuration/\(HueSyncControllerTests.areaID)"):
                    return .init(body: current.areaBody)
                case ("GET", "/clip/v2/resource/entertainment"):
                    return .init(body: services)
                case ("GET", "/clip/v2/resource/light"):
                    return .init(body: lights)
                case ("PUT", "/clip/v2/resource/entertainment_configuration/\(HueSyncControllerTests.areaID)"):
                    let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    return body.contains("start")
                        ? .init(status: current.startStatus, body: current.startBody)
                        : .init(body: putOK)
                case let ("PUT", path) where path.hasPrefix("/clip/v2/resource/light/"):
                    return .init(status: current.lightPutStatus, body: putOK)
                default:
                    return .init(body: putOK)
                }
            }
        }

        /// Method and path of every request, in order.
        var calls: [String] {
            StubURLProtocol.requests(host: host).map { request in
                let path = request.url?.path(percentEncoded: false) ?? ""
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let action = body.contains("\"start\"") ? " start" : body.contains("\"stop\"") ? " stop" : ""
                return "\(request.httpMethod ?? "GET") \(path)\(action)"
            }
        }

        var lightPuts: [URLRequest] {
            StubURLProtocol.requests(host: host).filter {
                $0.httpMethod == "PUT" && ($0.url?.path(percentEncoded: false).hasPrefix("/clip/v2/resource/light/") ?? false)
            }
        }
    }

    private final class Transports: Sendable {
        let made = Mutex<[StubHueStreamTransport]>([])

        var count: Int {
            made.withLock { $0.count }
        }

        var last: StubHueStreamTransport? {
            made.withLock { $0.last }
        }
    }

    private final class FixedClock: Sendable {
        private let time = Mutex(0.0)

        /// Advances one 50 Hz tick per read.
        func next() -> Double {
            time.withLock { time in
                time += 0.02
                return time
            }
        }
    }

    private struct Harness {
        let controller: HueSyncController
        let bridge: Bridge
        let defaults: UserDefaults
        let transports: Transports

        var transport: StubHueStreamTransport? {
            transports.last
        }
    }

    private func makeHarness(
        paired: Bool = true,
        areaID: String? = Self.areaID
    ) throws -> Harness {
        let bridge = try Bridge()
        let suite = "HueSyncControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        PlayerSettings.Hue.setEntertainmentAreaID(areaID, in: defaults)
        let transports = Transports()
        let address = HueBridgeAddress(id: "001788fffe000000", host: bridge.host)
        let secrets = HueBridgeSecrets(
            credentials: HueBridgeCredentials(
                applicationKey: "fixture-application-key",
                clientKey: "00112233445566778899AABBCCDDEEFF"
            ),
            certificatePin: nil
        )
        let clock = FixedClock()
        let dependencies = HueSyncDependencies(
            pairedBridge: { paired ? (address, secrets) : nil },
            makeClient: { address, secrets in
                HueBridgeClient(
                    host: address.host,
                    applicationKey: secrets.credentials.applicationKey,
                    session: StubURLProtocol.makeSession()
                )
            },
            makeTransport: { _, _ in
                let transport = StubHueStreamTransport()
                transports.made.withLock { $0.append(transport) }
                return transport
            },
            defaults: defaults,
            now: { clock.next() },
            tickInterval: nil
        )
        return Harness(
            controller: HueSyncController(dependencies: dependencies),
            bridge: bridge,
            defaults: defaults,
            transports: transports
        )
    }

    private static func solidGrid(_ value: UInt8) -> HueFrameGrid? {
        let count = HueFrameGrid.standardWidth * HueFrameGrid.standardHeight * 3
        return HueFrameGrid(
            width: HueFrameGrid.standardWidth,
            height: HueFrameGrid.standardHeight,
            rgb: [UInt8](repeating: value, count: count)
        )
    }

    /// Polls main-actor state the transport and sampler queues settle.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func startStreaming(_ harness: Harness, source: FakeFrameSource) async throws -> StubHueStreamTransport {
        await harness.controller.start(source: source, intensity: .moderate, reduceMotion: false).value
        let transport = try #require(harness.transport)
        transport.simulateReady()
        #expect(await eventually { harness.controller.state == .streaming })
        return transport
    }

    // MARK: - Ordering

    @Test func `start snapshots and persists before opening the area, then connects`() async throws {
        let harness = try makeHarness()
        let source = FakeFrameSource()

        await harness.controller.start(source: source, intensity: .moderate, reduceMotion: false).value

        #expect(harness.controller.state == .connecting)
        let calls = harness.bridge.calls
        #expect(calls.count == 5)
        #expect(calls.first == "GET /clip/v2/resource/entertainment_configuration/\(Self.areaID)")
        // Services and lights are read concurrently, in either order.
        #expect(Set(calls.dropFirst().prefix(2)) == [
            "GET /clip/v2/resource/entertainment",
            "GET /clip/v2/resource/light"
        ])
        #expect(Array(calls.suffix(2)) == [
            "GET /clip/v2/resource/entertainment_configuration/\(Self.areaID)",
            "PUT /clip/v2/resource/entertainment_configuration/\(Self.areaID) start"
        ])
        let snapshot = try #require(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults))
        #expect(snapshot.lights.map(\.lightID) == [Self.stripID, Self.playID])
        #expect(harness.transport?.startCount == 1)
    }

    @Test func `stop closes the stream, stops the area, restores, then clears the snapshot`() async throws {
        let harness = try makeHarness()
        let source = FakeFrameSource()
        let transport = try await startStreaming(harness, source: source)

        await harness.controller.stop().value

        #expect(transport.isCancelled)
        #expect(harness.controller.state == .idle)
        #expect(source.detachCount == 1)
        let calls = harness.bridge.calls
        let afterStart = Array(calls.suffix(from: 5))
        #expect(afterStart == [
            "PUT /clip/v2/resource/entertainment_configuration/\(Self.areaID) stop",
            "PUT /clip/v2/resource/light/\(Self.stripID)",
            "PUT /clip/v2/resource/light/\(Self.playID)"
        ])
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) == nil)
    }

    @Test func `a failed restore keeps the snapshot for the next launch`() async throws {
        let harness = try makeHarness()
        harness.bridge.config.withLock { $0.lightPutStatus = 500 }
        _ = try await startStreaming(harness, source: FakeFrameSource())

        await harness.controller.stop().value

        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) != nil)
    }

    @Test func `stop during setup waits for it, then closes what it opened`() async throws {
        let harness = try makeHarness()
        let setup = harness.controller.start(source: FakeFrameSource(), intensity: .moderate, reduceMotion: false)
        let close = harness.controller.stop()

        await setup.value
        await close.value

        #expect(harness.controller.state == .idle)
        let calls = harness.bridge.calls
        if calls.contains("PUT /clip/v2/resource/entertainment_configuration/\(Self.areaID) start") {
            #expect(calls.contains("PUT /clip/v2/resource/entertainment_configuration/\(Self.areaID) stop"))
        }
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) == nil)
    }

    @Test func `nothing happens without a paired bridge or an area`() async throws {
        for harness in try [makeHarness(paired: false), makeHarness(areaID: nil)] {
            await harness.controller.start(source: FakeFrameSource(), intensity: .moderate, reduceMotion: false).value

            #expect(harness.controller.state == .idle)
            #expect(harness.bridge.calls.isEmpty)
            #expect(harness.transport == nil)
        }
    }

    @Test func `intensity off starts nothing`() async throws {
        let harness = try makeHarness()

        await harness.controller.start(source: FakeFrameSource(), intensity: .off, reduceMotion: false).value

        #expect(harness.controller.state == .idle)
        #expect(harness.bridge.calls.isEmpty)
    }

    // MARK: - Area in use

    @Test func `an area another app streams to is left alone`() async throws {
        let harness = try makeHarness()
        let active = try hueFixture("hue-entertainment-configuration-active.json")
        harness.bridge.config.withLock { $0.areaBody = active }

        await harness.controller.start(source: FakeFrameSource(), intensity: .moderate, reduceMotion: false).value
        await harness.controller.stop().value

        #expect(harness.controller.state == .areaInUse || harness.controller.state == .idle)
        #expect(harness.bridge.calls == ["GET /clip/v2/resource/entertainment_configuration/\(Self.areaID)"])
        #expect(harness.transport == nil)
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) == nil)
    }

    @Test func `area in use is published and never retried`() async throws {
        let harness = try makeHarness()
        let active = try hueFixture("hue-entertainment-configuration-active.json")
        harness.bridge.config.withLock { $0.areaBody = active }

        await harness.controller.start(source: FakeFrameSource(), intensity: .moderate, reduceMotion: false).value
        try? await Task.sleep(for: .milliseconds(50))

        #expect(harness.controller.state == .areaInUse)
        #expect(harness.bridge.calls.count == 1)
    }

    @Test func `a start the bridge refuses sends no stop and restores nothing`() async throws {
        let harness = try makeHarness()
        let refused = try hueFixture("hue-put-error.json")
        harness.bridge.config.withLock { $0.startBody = refused }

        await harness.controller.start(source: FakeFrameSource(), intensity: .moderate, reduceMotion: false).value
        await harness.controller.stop().value

        #expect(harness.controller.state == .areaInUse)
        let calls = harness.bridge.calls
        #expect(!calls.contains { $0.hasSuffix(" stop") })
        #expect(harness.bridge.lightPuts.isEmpty)
        #expect(harness.transport == nil)
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) == nil)
    }

    // MARK: - Streaming

    @Test func `frames become packets and missing frames keep the stream alive`() async throws {
        let harness = try makeHarness()
        let source = FakeFrameSource()
        let transport = try await startStreaming(harness, source: source)

        harness.controller.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.sent.isEmpty)

        source.sample = try .frame(.grid(#require(Self.solidGrid(200))))
        harness.controller.tick()
        #expect(await eventually { transport.sent.count == 1 })

        source.sample = .noFrame
        for _ in 0 ..< 3 {
            harness.controller.tick()
        }
        #expect(await eventually { transport.sent.count == 4 })
        let packets = transport.sent
        #expect(packets.allSatisfy { $0.count == HueStreamMessage.headerLength + 2 * HueStreamMessage.channelLength })
        #expect(harness.controller.state == .streaming)
    }

    @Test func `an unavailable source is published once and holds the colours`() async throws {
        let harness = try makeHarness()
        let source = FakeFrameSource()
        source.sample = try .frame(.grid(#require(Self.solidGrid(120))))
        let transport = try await startStreaming(harness, source: source)
        harness.controller.tick()

        source.sample = .unavailable(.unsupportedContent)
        harness.controller.tick()
        harness.controller.tick()

        #expect(harness.controller.state == .unavailable(.unsupportedContent))
        #expect(await eventually { transport.sent.count == 3 })

        source.sample = try .frame(.grid(#require(Self.solidGrid(120))))
        harness.controller.tick()
        #expect(harness.controller.state == .streaming)
    }

    @Test func `swapping the source keeps the stream and detaches the old tap`() async throws {
        let harness = try makeHarness()
        let first = FakeFrameSource()
        first.sample = try .frame(.grid(#require(Self.solidGrid(30))))
        let transport = try await startStreaming(harness, source: first)
        harness.controller.tick()

        let second = FakeFrameSource()
        second.sample = try .frame(.grid(#require(Self.solidGrid(220))))
        harness.controller.setSource(second)
        harness.controller.tick()

        #expect(first.detachCount == 1)
        #expect(second.detachCount == 0)
        #expect(await eventually { transport.sent.count == 2 })
        #expect(transport.startCount == 1)
        #expect(harness.transports.count == 1)
        let putStarts = harness.bridge.calls.filter { $0.hasSuffix(" start") }
        #expect(putStarts.count == 1)
    }

    @Test func `a lost stream ends the session and restores without retrying`() async throws {
        let harness = try makeHarness()
        let transport = try await startStreaming(harness, source: FakeFrameSource())

        transport.simulateFailure(.connectionLost)

        #expect(await eventually { harness.controller.state == .error(.stream(.connectionLost)) })
        #expect(await eventually { PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) == nil })
        #expect(harness.bridge.calls.contains {
            $0 == "PUT /clip/v2/resource/entertainment_configuration/\(Self.areaID) stop"
        })
        #expect(harness.transports.count == 1)
    }

    @Test func `a stream failure is kept as the last error and never touches playback QoE`() async throws {
        let harness = try makeHarness()
        let qoeBefore = PlaybackQoE.shared.summary
        let transport = try await startStreaming(harness, source: FakeFrameSource())

        transport.simulateFailure(.handshakeFailed)

        #expect(await eventually { harness.controller.lastError == .stream(.handshakeFailed) })
        await harness.controller.stop().value
        #expect(harness.controller.lastError == .stream(.handshakeFailed))
        #expect(PlaybackQoE.shared.summary.engineFallbacks == qoeBefore.engineFallbacks)
    }

    @Test func `a failed restore is kept as the last error`() async throws {
        let harness = try makeHarness()
        harness.bridge.config.withLock { $0.lightPutStatus = 500 }
        _ = try await startStreaming(harness, source: FakeFrameSource())

        await harness.controller.stop().value

        #expect(harness.controller.state == .idle)
        #expect(harness.controller.lastError != nil)
    }

    @Test func `intensity off ends a running session`() async throws {
        let harness = try makeHarness()
        let transport = try await startStreaming(harness, source: FakeFrameSource())

        harness.controller.setIntensity(.off)
        await harness.controller.stop().value

        #expect(transport.isCancelled)
        #expect(harness.controller.state == .idle)
        #expect(harness.bridge.calls.contains { $0.hasSuffix(" stop") })
    }

    // MARK: - Crash restore

    @Test func `a leftover snapshot is restored at launch and cleared`() async throws {
        let harness = try makeHarness()
        let snapshot = HueLightSnapshot(lights: [
            .init(lightID: Self.stripID, isOn: true, brightness: 30, color: .mirek(300))
        ])
        PlayerSettings.Hue.saveRestoreSnapshot(snapshot, in: harness.defaults)

        await harness.controller.restoreLeftoverSnapshot()?.value

        #expect(harness.bridge.lightPuts.map { $0.url?.lastPathComponent } == [Self.stripID])
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) == nil)
    }

    @Test func `no leftover restore without a paired bridge`() throws {
        let harness = try makeHarness(paired: false)
        PlayerSettings.Hue.saveRestoreSnapshot(HueLightSnapshot(lights: []), in: harness.defaults)

        #expect(harness.controller.restoreLeftoverSnapshot() == nil)
        #expect(harness.bridge.calls.isEmpty)
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) != nil)
    }

    @Test func `a leftover snapshot waits while the area still streams`() async throws {
        let harness = try makeHarness()
        let active = try hueFixture("hue-entertainment-configuration-active.json")
        harness.bridge.config.withLock { $0.areaBody = active }
        PlayerSettings.Hue.saveRestoreSnapshot(HueLightSnapshot(lights: []), in: harness.defaults)

        await harness.controller.restoreLeftoverSnapshot()?.value

        #expect(harness.bridge.lightPuts.isEmpty)
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) != nil)
    }

    @Test func `a new session keeps the leftover state instead of the lamps' current colours`() async throws {
        let harness = try makeHarness()
        let leftover = HueLightSnapshot(lights: [
            .init(lightID: Self.stripID, isOn: true, brightness: 30, color: .mirek(300))
        ])
        PlayerSettings.Hue.saveRestoreSnapshot(leftover, in: harness.defaults)

        await harness.controller.start(source: FakeFrameSource(), intensity: .moderate, reduceMotion: false).value

        let snapshot = try #require(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults))
        #expect(snapshot.lights.map(\.lightID) == [Self.stripID, Self.playID])
        #expect(snapshot.lights.first == leftover.lights.first)
    }
}

// MARK: - Backgrounding

extension HueSyncControllerTests {
    @Test func `suspend restores the lamps but keeps the source for the next start`() async throws {
        let harness = try makeHarness()
        let source = FakeFrameSource()
        let transport = try await startStreaming(harness, source: source)

        await harness.controller.suspend().value

        #expect(transport.isCancelled)
        #expect(harness.controller.state == .idle)
        #expect(source.detachCount == 1)
        #expect(harness.controller.frameSource === source)
        #expect(PlayerSettings.Hue.restoreSnapshot(in: harness.defaults) == nil)
    }
}

/// A committed Hue fixture, read from disk (not the test bundle, which
/// flattens resources).
private func hueFixture(_ name: String, filePath: String = #filePath) throws -> String {
    let url = repoRootURL(filePath: filePath).appendingPathComponent("LumeTests/Fixtures/Hue/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}
