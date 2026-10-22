import Foundation
@testable import Lume
import LumeCloudKit
import Testing

struct LumeCloudErrorDescriptionTests {
    private static let everyCase: [LumeCloudError] = [
        .badRequest(message: "rid 7f3a rejected"),
        .badAuth,
        .deviceRevoked,
        .signupClosed,
        .accountDeleted,
        .notFound,
        .accountExists,
        .pairingAlreadySealed,
        .resyncRequired,
        .recordTooLarge,
        .rateLimited(retryAfter: 30),
        .quotaExceeded,
        .server(status: 503, code: "unavailable"),
        .transport(URLError(.timedOut)),
        .decoding("missing key seq at changes.0"),
        .missingCredentials
    ]

    @Test func `every case has a sentence and a log detail`() {
        for error in Self.everyCase {
            #expect(!LumeCloudErrorDescription.message(for: error).isEmpty, "\(error)")
            #expect(!LumeCloudErrorDescription.logDetail(for: error).isEmpty, "\(error)")
        }
    }

    @Test func `account errors read as their own sentence, not the generic fallback`() {
        let errors: [LumeCloudAccountError] = [
            .unavailable, .notJoined, .alreadyJoined, .keychainUnavailable, .invalidPairingCode, .pairingExpired,
            .pairingFailed, .serverMismatch, .cannotRevokeCurrentDevice, .invalidRecoveryKey, .recoveryKeyTypo,
            .wrongRecoveryKey
        ]
        let fallback = LogRedaction.scrubURLs(in: (LumeCloudAccountError.pairingExpired as any Error).localizedDescription)
        for error in errors {
            let message = LumeCloudErrorDescription.message(for: error as any Error)
            #expect(!message.isEmpty && message != fallback, "\(error)")
        }
        #expect(LumeCloudErrorDescription.message(for: LumeCloudAccountError.pairingExpired as any Error)
            == LumeCloudErrorDescription.message(for: LumeCloudError.notFound))
    }

    @Test func `states shared with the status row read the same`() {
        #expect(LumeCloudErrorDescription.message(for: .quotaExceeded) == "Lume Cloud storage is full. New changes stay on this device.")
        #expect(LumeCloudErrorDescription.message(for: .rateLimited(retryAfter: nil)) == "Lume Cloud is busy. Sync will retry automatically.")
        #expect(LumeCloudErrorDescription.message(for: .transport(URLError(.notConnectedToInternet)))
            == "Lume Cloud can’t be reached. Sync resumes automatically.")
    }

    @Test func `an existing account points to joining instead`() {
        let message = "This account already exists. Join with a code or your recovery key instead."
        #expect(LumeCloudErrorDescription.message(for: .accountExists) == message)
        #expect(LumeCloudErrorDescription.actionMessage(for: LumeCloudError.accountExists) == message)
        #expect(LumeCloudErrorDescription.logDetail(for: .accountExists) == "accountExists")
    }

    @Test func `one-off actions ask to try again instead of promising a retry`() {
        let tryAgain = "Lume Cloud can’t be reached right now. Try again in a moment."
        #expect(LumeCloudErrorDescription.actionMessage(for: LumeCloudError.transport(URLError(.notConnectedToInternet))) == tryAgain)
        #expect(LumeCloudErrorDescription.actionMessage(for: LumeCloudError.server(status: 503, code: "unavailable")) == tryAgain)
        #expect(LumeCloudErrorDescription.actionMessage(for: LumeCloudError.rateLimited(retryAfter: 5))
            == "Lume Cloud is busy. Try again in a moment.")
        #expect(LumeCloudErrorDescription.actionMessage(for: LumeCloudError.signupClosed)
            == LumeCloudErrorDescription.message(for: .signupClosed))
        #expect(LumeCloudErrorDescription.actionMessage(for: LumeCloudAccountError.notJoined)
            == LumeCloudErrorDescription.message(for: LumeCloudAccountError.notJoined))
    }

    @Test func `the server's free text never reaches either rendering`() {
        let error = LumeCloudError.badRequest(message: "rid 7f3a rejected for acct_fictional01")
        #expect(!LumeCloudErrorDescription.message(for: error).contains("acct_fictional01"))
        #expect(LumeCloudErrorDescription.logDetail(for: error) == "badRequest")
    }

    @Test func `log detail names status, code and retry delay`() {
        #expect(LumeCloudErrorDescription.logDetail(for: .server(status: 503, code: "unavailable"))
            == "server(status: 503, code: unavailable)")
        #expect(LumeCloudErrorDescription.logDetail(for: .server(status: 502, code: nil)) == "server(status: 502, code: none)")
        #expect(LumeCloudErrorDescription.logDetail(for: .rateLimited(retryAfter: 1.2)) == "rateLimited(retryAfter: 2s)")
        #expect(LumeCloudErrorDescription.logDetail(for: .transport(URLError(.timedOut))) == "transport(NSURLErrorDomain -1001)")
        #expect(LumeCloudErrorDescription.logDetail(for: .deviceRevoked) == "deviceRevoked")
        #expect(LumeCloudErrorDescription.logDetail(for: .pairingAlreadySealed) == "pairingAlreadySealed")
    }

    @Test func `an unexpected server code is reduced to identifier characters`() {
        let detail = LumeCloudErrorDescription.logDetail(for: .server(status: 500, code: "oops Bearer abc.def https://x.test/"))
        #expect(detail == "server(status: 500, code: oopsBearerabcdefhttpsxtest)")
    }

    @Test func `other errors fall back to a redacted rendering`() {
        let error = NSError(domain: "TestDomain", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed at https://cloud.example.test/v1/x"])
        #expect(LumeCloudErrorDescription.message(for: error) == "failed at https://<redacted>")
        #expect(LumeCloudErrorDescription.logDetail(for: error) == "TestDomain 3: failed at https://<redacted>")
    }

    @Test func `server kind names the build's server without its address`() throws {
        #expect(LumeCloudConfig.serverKind(for: LumeCloudAPI.officialURL) == .official)
        #expect(LumeCloudConfig.serverKind(for: LumeCloudAPI.stagingURL) == .staging)
        #expect(try LumeCloudConfig.serverKind(for: #require(URL(string: "https://cloud.getlume.org/"))) == .official)
        #expect(try LumeCloudConfig.serverKind(for: #require(URL(string: "https://sync.example.test"))) == .custom)
    }
}
