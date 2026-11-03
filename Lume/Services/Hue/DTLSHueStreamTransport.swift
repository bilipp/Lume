//
//  DTLSHueStreamTransport.swift
//  Lume
//
//  The Hue Entertainment stream over DTLS 1.2 on UDP 2100: PSK identity is
//  the application key, the PSK the hex-decoded client key. Both PSK AES-GCM
//  suites are offered — a real bridge picked 0x00A9 although 0x00A8 was
//  offered too (see `LumeTests/Fixtures/Hue/README.md`).
//

#if os(tvOS)
    import Foundation
    import Network
    import os

    /// Every mutable property is confined to `queue`.
    final nonisolated class DTLSHueStreamTransport: HueStreamTransport, @unchecked Sendable {
        static let port: NWEndpoint.Port = 2100
        private static let handshakeTimeout: DispatchTimeInterval = .seconds(10)
        /// Packets handed to the connection but not yet processed. Past this the
        /// next frame is dropped instead of queueing behind stale ones.
        private static let maximumPendingSends = 2

        private let queue = DispatchQueue(label: "app.lume.hue.stream", qos: .userInteractive)
        private let connection: NWConnection
        private var onStateChange: (@Sendable (HueStreamTransportState) -> Void)?
        private var isReady = false
        private var isFinished = false
        private var pendingSends = 0

        /// Nil when the credentials can't key a DTLS session.
        init?(host: String, credentials: HueBridgeCredentials) {
            guard !host.isEmpty, let psk = credentials.pskBytes, !psk.isEmpty,
                  !credentials.applicationKey.isEmpty
            else { return nil }
            let identity = Data(credentials.applicationKey.utf8)

            let dtls = NWProtocolTLS.Options()
            let security = dtls.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(security, .DTLSv12)
            sec_protocol_options_set_max_tls_protocol_version(security, .DTLSv12)
            sec_protocol_options_add_pre_shared_key(
                security,
                Self.dispatchData(psk) as __DispatchData,
                Self.dispatchData(identity) as __DispatchData
            )
            for suite: UInt16 in [0x00A8, 0x00A9] {
                if let ciphersuite = tls_ciphersuite_t(rawValue: suite) {
                    sec_protocol_options_append_tls_ciphersuite(security, ciphersuite)
                }
            }
            let parameters = NWParameters(dtls: dtls, udp: NWProtocolUDP.Options())
            connection = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: parameters)
        }

        func start(onStateChange: @escaping @Sendable (HueStreamTransportState) -> Void) {
            queue.async { [self] in
                guard !isFinished, self.onStateChange == nil else { return }
                self.onStateChange = onStateChange
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                connection.start(queue: queue)
                onStateChange(.connecting)
                queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
                    guard let self, !isReady else { return }
                    fail(.timedOut)
                }
            }
        }

        func send(_ packet: Data) {
            queue.async { [self] in
                guard isReady, !isFinished, pendingSends < Self.maximumPendingSends else { return }
                pendingSends += 1
                connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
                    self?.pendingSends -= 1
                })
            }
        }

        func cancel() {
            queue.async { [self] in
                guard !isFinished else { return }
                _ = finish()
            }
        }

        private func handle(_ state: NWConnection.State) {
            guard !isFinished else { return }
            switch state {
            case .ready:
                isReady = true
                onStateChange?(.ready)
            case let .waiting(error):
                // Waiting after the handshake, or behind a declined local-network
                // prompt, never recovers in time for a live picture.
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    fail(.localNetworkDenied)
                } else if isReady {
                    fail(.connectionLost)
                } else {
                    let reason = LogRedaction.describe(error)
                    Logger.network.log("Hue stream waiting: \(reason, privacy: .public)")
                }
            case .failed:
                fail(isReady ? .connectionLost : .handshakeFailed)
            default:
                break
            }
        }

        private func fail(_ error: HueStreamTransportError) {
            guard !isFinished else { return }
            let reason = LogRedaction.describe(error)
            Logger.network.error("Hue stream failed: \(reason, privacy: .public)")
            finish()?(.failed(error))
        }

        /// Returns the state handler that was set, for a last call.
        private func finish() -> (@Sendable (HueStreamTransportState) -> Void)? {
            let handler = onStateChange
            isFinished = true
            isReady = false
            onStateChange = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            return handler
        }

        private static func dispatchData(_ data: Data) -> DispatchData {
            data.withUnsafeBytes { DispatchData(bytes: $0) }
        }
    }
#endif
