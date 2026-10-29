import Foundation
@testable import Lume
import Testing

struct CastReceiverTests {
    @Test func `receiver is the Default Media Receiver`() {
        #expect(CastReceiver.appID == "CC1AD845")
    }

    /// Without both Bonjour types iOS hides Cast receivers from discovery
    /// and the device sheet stays empty.
    @Test(arguments: ["_googlecast._tcp", "_\(CastReceiver.appID)._googlecast._tcp"])
    func `cast Bonjour service is declared in Info plist`(service: String) throws {
        let declared = try #require(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        #expect(declared.contains(service), "\(service) missing from NSBonjourServices")
    }
}
