//
//  HueStreamTransport.swift
//  Lume
//
//  The datagram channel a Hue Entertainment stream runs over. The bridge only
//  accepts it after the area was started over CLIP v2; the real transport
//  (`DTLSHueStreamTransport`, tvOS) is DTLS 1.2 with the pairing's PSK, and
//  tests drive a stub.
//

import Foundation

nonisolated enum HueStreamTransportError: Error, Hashable {
    /// The client key isn't a hex string, or the application key is empty.
    case invalidCredentials
    /// The local-network permission was declined.
    case localNetworkDenied
    /// The DTLS handshake was refused — wrong key, or the area isn't started.
    case handshakeFailed
    /// No handshake within the transport's deadline.
    case timedOut
    /// The connection failed after it was up.
    case connectionLost
}

nonisolated enum HueStreamTransportState: Hashable {
    case connecting
    case ready
    /// Final: the transport sends nothing more and reports no further state.
    case failed(HueStreamTransportError)
}

/// Thread-safe: `send` is called from the frame pipeline, off the main actor,
/// up to ~50 times a second. State changes arrive on the transport's own queue,
/// never after `cancel()`.
nonisolated protocol HueStreamTransport: AnyObject, Sendable {
    func start(onStateChange: @escaping @Sendable (HueStreamTransportState) -> Void)
    /// Drops the packet when the transport isn't ready or is still busy with
    /// earlier ones: a stale colour is worth less than the next frame's.
    func send(_ packet: Data)
    func cancel()
}
