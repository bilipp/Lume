import CoreFoundation
import Foundation

/// Literal, provider-registered values. Nil means omitted; "" means explicitly empty.
nonisolated struct StalkerIdentity: Codable, Equatable {
    var serialNumber: String?
    var deviceId1: String?
    var deviceId2: String?
    var signature1: String?
    var signature2: String?

    var isConfigured: Bool {
        serialNumber != nil || deviceId1 != nil || deviceId2 != nil || signature1 != nil || signature2 != nil
    }

    /// IPTVnator's get_profile contract; no identifiers are derived or defaulted.
    var profileQuery: [URLQueryItem] {
        [
            ("sn", serialNumber), ("device_id", deviceId1), ("device_id2", deviceId2),
            ("signature", signature1), ("signature2", signature2)
        ].compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    }

    var authQuery: [URLQueryItem] {
        [("device_id", deviceId1), ("device_id2", deviceId2)]
            .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    }

    func validate() throws {
        // SN is also an HTTP header. Reject unsafe input, never silently trim it.
        if let serialNumber,
           serialNumber.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 })
        {
            throw StalkerIdentityError.invalidProfile
        }
    }
}

nonisolated enum StalkerIdentityError: LocalizedError {
    case invalidProfile
    case invalidMACAddress
    case storageUnavailable
    case localIdentityRequired

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            String(localized: "Invalid Stalker profile. Check the version, fields, aliases, portal URL and MAC address.")
        case .invalidMACAddress:
            String(localized: "Enter a valid MAC address (for example, 00:1A:79:00:00:01).")
        case .storageUnavailable:
            String(localized: "Protected identity storage is unavailable. Unlock this device and try again.")
        case .localIdentityRequired:
            String(localized: "This playlist needs its device-local Stalker identity. Review and save the existing registered identity in Edit before connecting.")
        }
    }
}

nonisolated extension StalkerIdentity: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "StalkerIdentity(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

/// A single household profile, not an IPTVnator backup or a collection of accounts.
nonisolated struct StalkerPrivateProfile {
    let displayName: String
    let portalURL: String
    let mac: String
    let identity: StalkerIdentity

    static func decode(_ data: Data) throws -> Self {
        do {
            guard data.count <= 65536,
                  let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw StalkerIdentityError.invalidProfile }
            let allowed: Set = [
                "schemaVersion", "displayName", "portalUrl", "mac", "serialNumber",
                "deviceId1", "deviceId2", "signature", "signature1", "signature2"
            ]
            guard Set(fields.keys).isSubset(of: allowed),
                  !(fields.keys.contains("signature") && fields.keys.contains("signature1"))
            else { throw StalkerIdentityError.invalidProfile }
            if let version = fields["schemaVersion"] {
                guard let number = version as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number == 1
                else { throw StalkerIdentityError.invalidProfile }
            }
            func string(_ key: String, required: Bool = false) throws -> String? {
                guard let value = fields[key] else {
                    if required { throw StalkerIdentityError.invalidProfile }
                    return nil
                }
                guard let value = value as? String else { throw StalkerIdentityError.invalidProfile }
                return value
            }
            guard let portal = try string("portalUrl", required: true),
                  let url = URLComponents(string: portal),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil,
                  let rawMAC = try string("mac", required: true)
            else { throw StalkerIdentityError.invalidProfile }
            let mac = StalkerMAC.normalize(rawMAC)
            guard StalkerMAC.isValid(mac) else { throw StalkerIdentityError.invalidProfile }
            let identity = try StalkerIdentity(
                serialNumber: string("serialNumber"), deviceId1: string("deviceId1"),
                deviceId2: string("deviceId2"), signature1: string(fields["signature"] == nil ? "signature1" : "signature"),
                signature2: string("signature2")
            )
            try identity.validate()
            return try Self(displayName: string("displayName") ?? "", portalURL: portal, mac: mac, identity: identity)
        } catch {
            // JSON/DecodingError descriptions can quote private source data.
            throw StalkerIdentityError.invalidProfile
        }
    }
}
