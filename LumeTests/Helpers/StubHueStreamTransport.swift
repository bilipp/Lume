//
//  StubHueStreamTransport.swift
//  LumeTests
//
//  A scripted `HueStreamTransport` for Hue session tests: records every
//  packet sent while ready, and the `simulate…` helpers drive state the way
//  `DTLSHueStreamTransport` reports it — synchronously, on the caller.
//

import Foundation
@testable import Lume
import Synchronization

final class StubHueStreamTransport: HueStreamTransport {
    struct State {
        var onStateChange: (@Sendable (HueStreamTransportState) -> Void)?
        var startCount = 0
        var isReady = false
        var isCancelled = false
        /// Packets accepted while ready, in order.
        var sent: [Data] = []
        /// Packets offered while not ready or after cancel, dropped like the real transport.
        var droppedCount = 0
    }

    let state = Mutex(State())

    var sent: [Data] {
        state.withLock { $0.sent }
    }

    var startCount: Int {
        state.withLock { $0.startCount }
    }

    var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    var droppedCount: Int {
        state.withLock { $0.droppedCount }
    }

    func start(onStateChange: @escaping @Sendable (HueStreamTransportState) -> Void) {
        state.withLock {
            $0.startCount += 1
            $0.onStateChange = onStateChange
        }
        onStateChange(.connecting)
    }

    func send(_ packet: Data) {
        state.withLock {
            if $0.isReady, !$0.isCancelled {
                $0.sent.append(packet)
            } else {
                $0.droppedCount += 1
            }
        }
    }

    func cancel() {
        state.withLock {
            $0.isCancelled = true
            $0.isReady = false
            $0.onStateChange = nil
        }
    }

    func simulateReady() {
        let handler = state.withLock { state -> (@Sendable (HueStreamTransportState) -> Void)? in
            guard !state.isCancelled else { return nil }
            state.isReady = true
            return state.onStateChange
        }
        handler?(.ready)
    }

    /// Final, as on the real transport: nothing is sent or reported afterwards.
    func simulateFailure(_ error: HueStreamTransportError) {
        let handler = state.withLock { state -> (@Sendable (HueStreamTransportState) -> Void)? in
            guard !state.isCancelled else { return nil }
            let handler = state.onStateChange
            state.isReady = false
            state.isCancelled = true
            state.onStateChange = nil
            return handler
        }
        handler?(.failed(error))
    }
}
