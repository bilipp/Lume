import Foundation
@testable import Lume
import Testing

/// Replays a customer-reported portal (2026-09-27) with an unregistered MAC: the handshake
/// succeeds, `get_profile` answers with a status-1 refusal, and every catalog
/// call returns HTTP 200 with a plain-text `Authorization failed.`. Before the
/// fix that surfaced as "Failed to read the portal response" on the live
/// channel step, after the category steps had silently come back empty.
struct StalkerDeviceBlockedTests {
    private static let blockedProfile = """
    {"js":{"status":1,"msg":"Device conflict - Serial Number mismatch",\
    "block_msg":"Please contact your provider<br>to register this device.(SN1001)"},\
    "text":"generated in: 0.047s"}
    """

    private func client(host: String, profile: String) -> StalkerClient {
        let handshake = #"{"js":{"token":"TESTTOKEN","random":"x","not_valid":0}}"#
        let unauthorized = StubURLProtocol.Response(body: "Authorization failed.")
        StubURLProtocol.register(host: host, query: ("action", "handshake"), response: .init(body: handshake))
        StubURLProtocol.register(host: host, query: ("action", "get_profile"), response: .init(body: profile))
        StubURLProtocol.register(host: host, query: ("action", "get_all_channels"), response: unauthorized)
        return StalkerClient(
            configuration: StalkerClient.Configuration(
                portalURL: "http://\(host)/stalker_portal/c/",
                macAddress: "00:1A:79:12:34:56"
            ),
            urlSession: StubURLProtocol.makeSession()
        )
    }

    @Test func `a refused device fails authentication with a sanitized reason`() async {
        let client = client(host: "blocked.stalker.test", profile: Self.blockedProfile)
        do {
            _ = try await client.authenticate()
            Issue.record("authenticate() should have thrown")
        } catch let StalkerError.deviceBlocked(reason) {
            #expect(reason == .serialMismatch)
            let error = StalkerError.deviceBlocked(reason)
            #expect(!error.localizedDescription.contains("SN1001"))
            #expect(!error.logDescription.contains("SN1001"))
            #expect(error.logDescription.contains("serial mismatch"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `a plain-text Authorization failed is an auth error, not a decode error`() async {
        let client = client(host: "unauthorized.stalker.test", profile: #"{"js":{"status":0}}"#)
        await #expect(throws: StalkerError.self) { _ = try await client.getAllChannels() }
        do {
            _ = try await client.getAllChannels()
        } catch let error as StalkerError {
            guard case .authenticationFailed = error else {
                Issue.record("expected .authenticationFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `an active profile authenticates`() async throws {
        let client = client(
            host: "active.stalker.test",
            profile: #"{"js":{"status":0,"exp_date":"2027-01-01","phone":""}}"#
        )
        let profile = try await client.authenticate()
        #expect(!profile.isBlocked)
        #expect(profile.expDate == "2027-01-01")
    }

    @Test func `a non-zero status without a message is not a refusal`() throws {
        let profile = try JSONDecoder().decode(
            StalkerEnvelope<StalkerProfile>.self, from: Data(#"{"js":{"status":"1"}}"#.utf8)
        ).js
        #expect(profile.blockMessage == nil)
        #expect(!profile.isBlocked)
    }

    @Test func `authorization-failure sniff ignores JSON and long bodies`() {
        #expect(StalkerClient.isAuthorizationFailure(Data("Authorization failed.\n".utf8)))
        #expect(!StalkerClient.isAuthorizationFailure(Data(#"{"js":[]}"#.utf8)))
        #expect(!StalkerClient.isAuthorizationFailure(Data(String(repeating: "x", count: 300).utf8)))
    }
}
