//
//  HueTrustDelegate.swift
//  Lume
//
//  TLS trust for the one configured Hue Bridge. A bridge serves its own
//  certificate for an IP address, so the system trust store can't vouch for
//  it: the chain must end at Signify's private bridge root with the bridge id
//  as common name, or — for bridges whose certificate isn't Signify-issued —
//  match the leaf pinned on first use. Nothing else is ever accepted.
//

import CryptoKit
import Foundation
import os
import Security

/// What a bridge presented during the TLS handshake.
nonisolated struct HueServerIdentity: Hashable {
    var commonName: String?
    /// SHA-256 of the leaf certificate's DER bytes.
    var leafSHA256: Data
    /// The chain verifies against `HueTrust.signifyRootDER` and nothing else.
    var chainsToSignifyRoot: Bool
}

nonisolated enum HueTrustDecision: Hashable {
    case trusted
    /// No pin yet and no Signify chain: accept and pin this leaf.
    case pinOnFirstUse(Data)
    case rejected

    var accepts: Bool {
        self != .rejected
    }
}

nonisolated enum HueTrust {
    /// Signify's private CA for Hue Bridges (`CN=root-bridge, O=Philips Hue,
    /// C=NL`, ECDSA P-256, valid until 2038-01-19), DER as base64. SHA-256
    /// fingerprint F0:BD:8E:65:09:E8:2F:77:4D:63:BC:00:9D:53:88:C9:69:FE:3D:CF:7D:6D:54:1D:63:51:B7:2B:89:8D:8A:CF.
    static let signifyRootDER = Data(base64Encoded: """
    MIICMjCCAdigAwIBAgIUO7FSLbaxikuXAljzVaurLXWmFw4wCgYIKoZIzj0EAwIwOTELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVl\
    MRQwEgYDVQQDDAtyb290LWJyaWRnZTAiGA8yMDE3MDEwMTAwMDAwMFoYDzIwMzgwMTE5MDMxNDA3WjA5MQswCQYDVQQGEwJOTDEUMBIGA1UECgwL\
    UGhpbGlwcyBIdWUxFDASBgNVBAMMC3Jvb3QtYnJpZGdlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjNw2tx2AplOf9x86aTdvEcL1FU65QDxz\
    iKvBpW9XXSIcibAeQiKxegpq8Exbr9v6LBnYbna2VcaK0G22jOKkTqOBuTCBtjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBhjAdBgNV\
    HQ4EFgQUZ2ONTFrDT6o8ItRnKfqWKnHFGmQwdAYDVR0jBG0wa4AUZ2ONTFrDT6o8ItRnKfqWKnHFGmShPaQ7MDkxCzAJBgNVBAYTAk5MMRQwEgYD\
    VQQKDAtQaGlsaXBzIEh1ZTEUMBIGA1UEAwwLcm9vdC1icmlkZ2WCFDuxUi22sYpLlwJY81Wrqy11phcOMAoGCCqGSM49BAMCA0gAMEUCIEBYYEOs\
    a07TH7E5MJnGw557lVkORgit2Rm1h3B2sFgDAiEA1Fj/C3AN5psFMjo0//mrQebo0eKd3aWRx+pQY08mk48=
    """)

    /// The trust rule, free of `Security` types.
    ///
    /// - Parameters:
    ///   - bridgeID: The id the bridge must present as common name; nil before
    ///     it is known (a manual address being identified), when any bridge-id
    ///     shaped name passes and the caller compares it with what the bridge
    ///     reports.
    ///   - pin: The leaf pinned at pairing, if any.
    ///   - allowsFirstUse: Only while pairing; a paired bridge without a pin
    ///     was Signify-verified then and must stay so.
    static func decide(
        _ identity: HueServerIdentity,
        bridgeID: String?,
        pin: Data?,
        allowsFirstUse: Bool
    ) -> HueTrustDecision {
        guard let name = identity.commonName, isBridgeID(name) else { return .rejected }
        if let bridgeID, name.caseInsensitiveCompare(bridgeID) != .orderedSame {
            return .rejected
        }
        if identity.chainsToSignifyRoot { return .trusted }
        if let pin { return pin == identity.leafSHA256 ? .trusted : .rejected }
        return allowsFirstUse ? .pinOnFirstUse(identity.leafSHA256) : .rejected
    }

    /// 16 hex digits, as bridge ids and their certificates' common names are.
    static func isBridgeID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.allSatisfy(\.isHexDigit)
    }

    /// Reads what `decide` needs out of a server trust.
    static func identity(of trust: SecTrust) -> HueServerIdentity? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        var commonName: CFString?
        SecCertificateCopyCommonName(leaf, &commonName)
        let leafData = SecCertificateCopyData(leaf) as Data
        return HueServerIdentity(
            commonName: commonName as String?,
            leafSHA256: Data(SHA256.hash(data: leafData)),
            chainsToSignifyRoot: chainsToSignifyRoot(chain)
        )
    }

    /// Basic X.509 rather than SSL policy: the bridge is reached by IP and its
    /// certificate names the bridge id, never a host name.
    private static func chainsToSignifyRoot(_ chain: [SecCertificate]) -> Bool {
        guard let rootDER = signifyRootDER,
              let root = SecCertificateCreateWithData(nil, rootDER as CFData)
        else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

/// The session delegate of one `HueBridgeClient`. Records what the handshake
/// decided so the client can report a rejected certificate, a first-use pin
/// to store, and the common name an identification is checked against.
final nonisolated class HueTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    nonisolated struct Handshake: Hashable {
        var commonName: String?
        var firstUsePin: Data?
        var rejected = false
    }

    let bridgeID: String?
    let pin: Data?
    let allowsFirstUse: Bool
    private let state = OSAllocatedUnfairLock(initialState: Handshake())

    init(bridgeID: String?, pin: Data?, allowsFirstUse: Bool) {
        self.bridgeID = bridgeID
        self.pin = pin
        self.allowsFirstUse = allowsFirstUse
    }

    var handshake: Handshake {
        state.withLock { $0 }
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }

        let identity = HueTrust.identity(of: trust)
        let decision = identity.map {
            HueTrust.decide($0, bridgeID: bridgeID, pin: pin, allowsFirstUse: allowsFirstUse)
        } ?? .rejected
        state.withLock { handshake in
            handshake.rejected = !decision.accepts
            if decision.accepts { handshake.commonName = identity?.commonName }
            if case let .pinOnFirstUse(leaf) = decision { handshake.firstUsePin = leaf }
        }
        return decision.accepts
            ? (.useCredential, URLCredential(trust: trust))
            : (.cancelAuthenticationChallenge, nil)
    }
}
