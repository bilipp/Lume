import CryptoKit
import Foundation

extension StalkerClient {
    nonisolated struct Configuration {
        let portalURL: String
        let macAddress: String
        let username: String
        let password: String
        let timeout: TimeInterval
        let identity: StalkerIdentity
        let identityUnavailable: Bool

        init(
            portalURL: String,
            macAddress: String,
            username: String = "",
            password: String = "",
            timeout: TimeInterval = 30,
            identity: StalkerIdentity = StalkerIdentity(),
            identityUnavailable: Bool = false
        ) {
            self.portalURL = portalURL
            self.macAddress = macAddress
            self.username = username
            self.password = password
            self.timeout = timeout
            self.identity = identity
            self.identityUnavailable = identityUnavailable
        }

        init(playlist: Playlist, timeout: TimeInterval = 30) {
            let loaded = Result { try StalkerIdentityStore().load(for: playlist) }
            self.init(
                portalURL: playlist.serverURL,
                macAddress: playlist.macAddress ?? "",
                username: playlist.username,
                password: playlist.password,
                timeout: timeout,
                identity: (try? loaded.get()) ?? StalkerIdentity(),
                identityUnavailable: (try? loaded.get()) == nil
            )
        }

        private static let cacheSecret = SymmetricKey(size: .bits256)

        /// A process-keyed digest, not a credential-bearing dictionary key.
        var sessionKey: String {
            let fields: [String?] = [
                portalURL, macAddress, username, password, String(timeout),
                identity.serialNumber, identity.deviceId1, identity.deviceId2,
                identity.signature1, identity.signature2, String(identityUnavailable)
            ]
            var data = Data()
            for field in fields {
                if let field {
                    data.append(Data("\(field.utf8.count):\(field)".utf8))
                } else {
                    data.append(Data("-:".utf8))
                }
            }
            return HMAC<SHA256>.authenticationCode(for: data, using: Self.cacheSecret)
                .map { String(format: "%02x", $0) }.joined()
        }
    }
}

nonisolated extension StalkerClient.Configuration: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "StalkerConfiguration(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
