import Foundation
import LumeCloudKit

/// Pairing (PROTOCOL.md §4.5): a new device shows a code, a joined device looks
/// it up, confirms the new device's name and seals the account key to it.
extension LumeCloudBackend {
    // MARK: New device

    /// Joins an account through pairing: asks the server for a code, hands it to
    /// `onCode` to show, polls every `pairingPollInterval` until a joined device
    /// sealed the grant, then joins with it. Cancel the calling task to stop
    /// waiting.
    func joinWithPairingCode(onCode: (LumeCloudPairingCode) -> Void) async throws {
        try ensureCanJoin()
        let (privateKey, publicKey) = LumeCloudPairing.makeKeyPair()
        let anonymous = makeClient(nil)
        let ticket = try await anonymous.startPairing(
            publicKey: publicKey, deviceName: settings.deviceName, platform: .current
        )
        let expiresAt = Date(lumeCloudMilliseconds: Double(ticket.expiresAt))
        onCode(LumeCloudPairingCode(code: ticket.code, expiresAt: expiresAt))
        let sealed = try await pollPairing(ticket, expiresAt: expiresAt, client: anonymous)
        let grant: LumeCloudGrant
        do {
            grant = try LumeCloudPairing.open(sealed, privateKey: privateKey, code: ticket.code)
        } catch {
            throw LumeCloudAccountError.pairingFailed
        }
        guard LumeCloudConfig.resolve(grant.serverURL.absoluteString) == serverURL else {
            throw LumeCloudAccountError.serverMismatch
        }
        try await join(LumeCloudIdentity(accountId: grant.accountId, rootKey: grant.rootKey))
    }

    private func pollPairing(
        _ ticket: PairingTicket,
        expiresAt: Date,
        client: any LumeCloudAccountAPI
    ) async throws -> SealedGrant {
        while true {
            try Task.checkCancellation()
            guard now() < expiresAt else { throw LumeCloudAccountError.pairingExpired }
            var delay = pairingPollInterval
            do {
                if case let .sealed(sealed) = try await client.pairingResult(code: ticket.code, pollToken: ticket.pollToken) {
                    return sealed
                }
            } catch LumeCloudError.notFound {
                throw LumeCloudAccountError.pairingExpired
            } catch let LumeCloudError.rateLimited(retryAfter) {
                if let retryAfter, retryAfter > 0 {
                    delay = max(delay, .seconds(retryAfter))
                }
            } catch LumeCloudError.transport {
                // A dropped poll on a flaky network: the code is still valid, keep waiting.
            }
            try await Task.sleep(for: delay)
        }
    }

    // MARK: Joined device

    /// Looks up the device waiting behind `code` (six digits; spaces and
    /// separators are ignored) so the user can confirm its name and platform.
    func lookUpPairing(code: String) async throws -> LumeCloudPendingDevice {
        let normalized = try Self.normalizedPairingCode(code)
        do {
            let request = try await authenticated { client in try await client.pairingRequest(code: normalized) }
            return LumeCloudPendingDevice(
                code: normalized, name: request.deviceName, platform: request.platform.rawValue, publicKey: request.publicKey
            )
        } catch LumeCloudError.notFound {
            throw LumeCloudAccountError.pairingExpired
        }
    }

    /// Seals this account's key to the confirmed device. First writer wins: a
    /// device another account member already added throws `.pairingAlreadySealed`.
    func confirmPairing(_ device: LumeCloudPendingDevice) async throws {
        guard let identity else { throw LumeCloudAccountError.notJoined }
        let grant = LumeCloudGrant(accountId: identity.accountId, rootKey: identity.rootKey, serverURL: serverURL)
        let sealed = try LumeCloudPairing.seal(grant, to: device.publicKey, code: device.code)
        do {
            try await authenticated { client in try await client.sealPairing(code: device.code, sealed: sealed) }
        } catch LumeCloudError.notFound {
            throw LumeCloudAccountError.pairingExpired
        }
    }

    /// The six ASCII digits of `input`, with spaces and separators dropped.
    /// Anything else (letters, non-Western digits, a wrong length) is rejected.
    nonisolated static func normalizedPairingCode(_ input: String) throws -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let kept = input.unicodeScalars.filter { !separators.contains($0) }
        guard kept.count == 6, kept.allSatisfy({ ("0" ... "9").contains($0) }) else {
            throw LumeCloudAccountError.invalidPairingCode
        }
        return String(String.UnicodeScalarView(kept))
    }
}
