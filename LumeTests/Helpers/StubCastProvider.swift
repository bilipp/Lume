//
//  StubCastProvider.swift
//  LumeTests
//
//  A scripted `CastProvider` for `CastService` tests: settable devices,
//  connection and receiver status, an optional load failure, and a log of
//  what the service asked for. The `simulate…` helpers change state and fire
//  the matching event the way `GoogleCastProvider` does.
//

import Foundation
@testable import Lume

@MainActor
final class StubCastProvider: CastProvider {
    enum Call: Equatable {
        case startDiscovery
        case stopDiscovery
        case connect(String)
        case load(URL)
        case play
        case pause
        case seek(TimeInterval)
        case setVolume(Float)
        case endSession(stopReceiver: Bool)
    }

    var eventHandler: ((CastProviderEvent) -> Void)?

    var devices: [CastDevice] = []
    var connectionState: CastConnectionState = .idle
    var connectedDeviceName: String?
    var status = CastPlaybackStatus.idle
    /// Thrown by `load` when set.
    var loadFailure: CastError?
    private(set) var calls: [Call] = []

    func startDiscovery() {
        calls.append(.startDiscovery)
    }

    func stopDiscovery() {
        calls.append(.stopDiscovery)
    }

    func connect(to device: CastDevice) {
        calls.append(.connect(device.id))
    }

    func load(_ request: CastMediaRequest) async throws(CastError) {
        calls.append(.load(request.contentURL))
        if let loadFailure {
            throw loadFailure
        }
    }

    func play() {
        calls.append(.play)
    }

    func pause() {
        calls.append(.pause)
    }

    func seek(to position: TimeInterval) {
        calls.append(.seek(position))
    }

    func setVolume(_ volume: Float) {
        calls.append(.setVolume(volume))
    }

    func endSession(stopReceiver: Bool) {
        calls.append(.endSession(stopReceiver: stopReceiver))
    }

    // MARK: - Scripting

    func simulateDevices(_ devices: [CastDevice]) {
        self.devices = devices
        eventHandler?(.devicesChanged)
    }

    func simulateConnection(_ state: CastConnectionState, deviceName: String? = "Living Room TV") {
        connectionState = state
        connectedDeviceName = state == .idle ? nil : deviceName
        eventHandler?(.connectionChanged)
    }

    func simulateStatus(_ status: CastPlaybackStatus) {
        self.status = status
        eventHandler?(.statusChanged)
    }

    func simulatePlaying(at position: TimeInterval, duration: TimeInterval? = 3600) {
        simulateStatus(CastPlaybackStatus(
            hasMedia: true, position: position, duration: duration,
            isPlaying: true, isBuffering: false, volume: 1, idleReason: nil
        ))
    }

    func simulateIdle(_ reason: CastPlaybackStatus.IdleReason) {
        simulateStatus(CastPlaybackStatus(
            hasMedia: false, position: 0, duration: nil,
            isPlaying: false, isBuffering: false, volume: 1, idleReason: reason
        ))
    }

    func simulateSessionEnd(_ reason: CastSessionEnd.Reason) {
        connectionState = .idle
        connectedDeviceName = nil
        status = .idle
        eventHandler?(.sessionEnded(reason))
    }
}
