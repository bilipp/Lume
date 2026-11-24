import Foundation
@testable import Lume
import Testing

struct StalkerIdentityTests {
    private let profile = """
    {"schemaVersion":1,"displayName":"Synthetic","portalUrl":"https://portal.example.invalid/stalker_portal/",
    "mac":"00:1a:79:00:00:01","serialNumber":"SYNTHETIC-SERIAL","deviceId1":"SYNTHETIC-ONE",
    "deviceId2":"SYNTHETIC-TWO","signature":"SYNTHETIC-SIGNATURE","signature2":""}
    """

    @Test func `minimal private profile round trips literal values without a version marker`() throws {
        let versionless = profile.replacingOccurrences(of: #""schemaVersion":1,"#, with: "")
        let decoded = try StalkerPrivateProfile.decode(Data(versionless.utf8))
        #expect(decoded.mac == "00:1a:79:00:00:01")
        #expect(decoded.identity.serialNumber == "SYNTHETIC-SERIAL")
        #expect(decoded.identity.deviceId1 == "SYNTHETIC-ONE")
        #expect(decoded.identity.deviceId2 == "SYNTHETIC-TWO")
        #expect(decoded.identity.signature1 == "SYNTHETIC-SIGNATURE")
        #expect(decoded.identity.signature2 == "")
    }

    @Test func `absent empty and whitespace are distinct`() throws {
        let identity = StalkerIdentity(deviceId1: "", deviceId2: "  existing two & + % = ?  ")
        let restored = try JSONDecoder().decode(StalkerIdentity.self, from: JSONEncoder().encode(identity))
        #expect(restored == identity)
        #expect(restored.serialNumber == nil)
        #expect(restored.profileQuery == [
            URLQueryItem(name: "device_id", value: ""),
            URLQueryItem(name: "device_id2", value: "  existing two & + % = ?  ")
        ])
    }

    @Test(arguments: [
        #""signature1":"ALIAS","#,
        #""sn":"ALIAS","#,
        #""device_id":"ALIAS","#,
        #""schemaVersion":2,"#,
        #""schemaVersion":true,"#,
        #""username":"OTHER-ACCOUNT","#,
        #""deviceId1":null,"#
    ])
    func `reject unsupported versions aliases types and backup fields`(_ injected: String) {
        let minimal = #"{"portalUrl":"https://portal.example.invalid/c/","mac":"00:1A:79:00:00:01","signature":"one"}"#
        let json = "{" + injected + minimal.dropFirst()
        #expect(throws: StalkerIdentityError.self) { try StalkerPrivateProfile.decode(Data(json.utf8)) }
    }

    @Test(arguments: [
        "file:///private/profile", "ftp://portal.example.invalid/",
        "https://user:pass@portal.example.invalid/", "https://portal.example.invalid/?sn=secret", "portal.example.invalid"
    ])
    func `reject invalid or credential bearing portal URLs`(_ portal: String) {
        let json = #"{"portalUrl":""# + portal + #"","mac":"00:1A:79:00:00:01"}"#
        #expect(throws: StalkerIdentityError.self) { try StalkerPrivateProfile.decode(Data(json.utf8)) }
    }

    @Test func `signature1 alias alone is supported and absent optionals stay absent`() throws {
        let data = Data(#"{"portalUrl":"https://portal.example.invalid/","mac":"00:1A:79:00:00:01","signature1":""}"#.utf8)
        let identity = try StalkerPrivateProfile.decode(data).identity
        #expect(identity.signature1 == "")
        #expect(identity.deviceId1 == nil)
        #expect(identity.signature2 == nil)
    }

    @Test func `serial header injection is rejected without modifying the supplied value`() {
        let identity = StalkerIdentity(serialNumber: "SYNTHETIC\r\nInjected: secret")
        #expect(throws: StalkerIdentityError.self) { try identity.validate() }
        #expect(identity.serialNumber == "SYNTHETIC\r\nInjected: secret")
    }

    @Test func `cache key binds every identity credential and authentication setting`() {
        func key(_ identity: StalkerIdentity = StalkerIdentity(), user: String = "", password: String = "", timeout: Double = 30) -> String {
            StalkerClient.Configuration(
                portalURL: "https://cache.example.invalid/", macAddress: "00:1A:79:00:00:01",
                username: user, password: password, timeout: timeout, identity: identity
            ).sessionKey
        }
        let variants = [
            key(), key(StalkerIdentity(serialNumber: "")), key(StalkerIdentity(serialNumber: "SYNTHETIC")),
            key(StalkerIdentity(deviceId1: "SYNTHETIC")), key(StalkerIdentity(deviceId2: "SYNTHETIC")),
            key(StalkerIdentity(signature1: "SYNTHETIC")), key(StalkerIdentity(signature2: "SYNTHETIC")),
            key(user: "SYNTHETIC"), key(password: "SYNTHETIC"), key(timeout: 10)
        ]
        #expect(Set(variants).count == variants.count)
        #expect(key() == key())
        #expect(!variants.joined().contains("SYNTHETIC"))
        #expect(!variants.joined().contains("00:1A:79"))
    }

    @Test func `diagnostics never include provider text or nested transport secrets`() {
        let secret = "SYNTHETIC-SECRET"
        let transport = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
            NSLocalizedDescriptionKey: "failed \(secret) https://provider.example.invalid/?token=\(secret)"
        ])
        let errors: [StalkerError] = [
            .deviceBlocked, .networkError(transport),
            .decodingError(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: secret)))
        ]
        for error in errors {
            #expect(!LogRedaction.describe(error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
            #expect(!error.logDescription.contains(secret))
        }
        #expect(!String(reflecting: StalkerIdentity(serialNumber: secret)).contains(secret))
    }
}
