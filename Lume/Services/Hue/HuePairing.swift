//
//  HuePairing.swift
//  Lume
//
//  The v1-style `POST /api` that creates an application key once the bridge's
//  link button was pressed. CLIP v2 has no pairing endpoint of its own; the
//  key it returns is the `hue-application-key` header and the DTLS PSK
//  identity, the client key the PSK.
//

import Foundation

nonisolated struct HuePairingRequest: Encodable, Hashable {
    var deviceType: String
    var generateClientKey: Bool

    static let appleTV = HuePairingRequest(deviceType: "lume#appletv", generateClientKey: true)

    private enum CodingKeys: String, CodingKey {
        case deviceType = "devicetype"
        case generateClientKey = "generateclientkey"
    }
}

/// An application key and its entertainment client key. Both are secrets:
/// descriptions and mirrors never show them.
nonisolated struct HueBridgeCredentials: Codable, Hashable {
    /// The `username` of the pairing response.
    var applicationKey: String
    /// 32 hex characters; the DTLS pre-shared key once hex-decoded.
    var clientKey: String

    private enum CodingKeys: String, CodingKey {
        case applicationKey = "username"
        case clientKey = "clientkey"
    }

    /// The hex-decoded client key, or nil when it isn't an even-length hex string.
    var pskBytes: Data? {
        let digits = Array(clientKey.utf8)
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Self.nibble(digits[index]), let low = Self.nibble(digits[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

nonisolated extension HueBridgeCredentials: HueRedacted {}

nonisolated enum HuePairingOutcome: Hashable {
    case paired(HueBridgeCredentials)
    /// Error type 101: the user hasn't pressed the link button yet.
    case linkButtonNotPressed
    case failed(type: Int, description: String)

    static let linkButtonErrorType = 101

    /// Decodes the `[{"success": …}]` / `[{"error": …}]` array the bridge
    /// answers with. A success without a client key is a failure: light sync
    /// can't stream without it.
    init(responseData: Data) throws {
        let items = try JSONDecoder().decode([HuePairingResponseItem].self, from: responseData)
        if let success = items.lazy.compactMap(\.success).first {
            if let clientKey = success.clientkey, !clientKey.isEmpty {
                self = .paired(HueBridgeCredentials(applicationKey: success.username, clientKey: clientKey))
            } else {
                self = .failed(type: 0, description: "missing client key")
            }
        } else if let error = items.lazy.compactMap(\.error).first {
            self = error.type == Self.linkButtonErrorType
                ? .linkButtonNotPressed
                : .failed(type: error.type, description: error.description ?? "")
        } else {
            self = .failed(type: 0, description: "empty response")
        }
    }
}

private nonisolated struct HuePairingResponseItem: Decodable {
    nonisolated struct Success: Decodable {
        var username: String
        var clientkey: String?
    }

    nonisolated struct Failure: Decodable {
        var type: Int
        var description: String?
    }

    var success: Success?
    var error: Failure?
}
