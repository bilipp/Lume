import Foundation
@testable import Lume
import Testing

@MainActor
struct OpenSubtitlesSessionRenewalTests {
    private let stored = OpenSubtitlesSession(
        token: "expired",
        username: "viewer",
        host: "api.opensubtitles.com",
        allowedDownloads: 20,
        password: "secret"
    )

    private func freshSession() -> OpenSubtitlesSession {
        OpenSubtitlesSession(token: "fresh", username: "viewer", host: "vip-api.opensubtitles.com", allowedDownloads: 1000)
    }

    @Test func `a valid token is used as is`() async throws {
        var logins = 0
        let result = try await OpenSubtitlesService.performRenewing(
            session: stored,
            login: { _, _ in logins += 1; return freshSession() },
            request: { $0.token }
        )
        #expect(result.value == "expired")
        #expect(result.renewed == nil)
        #expect(logins == 0)
    }

    @Test func `an expired token is renewed and the request retried`() async throws {
        var tokensSeen: [String] = []
        var loginArguments: (String, String)?
        let result = try await OpenSubtitlesService.performRenewing(
            session: stored,
            login: { loginArguments = ($0, $1); return freshSession() },
            request: { session in
                tokensSeen.append(session.token)
                guard session.token == "fresh" else { throw OpenSubtitlesError.notAuthenticated }
                return session.token
            }
        )
        #expect(tokensSeen == ["expired", "fresh"])
        #expect(loginArguments?.0 == "viewer")
        #expect(loginArguments?.1 == "secret")
        #expect(result.value == "fresh")
        // The renewed session keeps the password and the host `/login` handed back.
        #expect(result.renewed?.password == "secret")
        #expect(result.renewed?.host == "vip-api.opensubtitles.com")
    }

    @Test func `a session saved without a password cannot be renewed`() async {
        var legacy = stored
        legacy.password = nil
        var logins = 0
        await #expect(throws: OpenSubtitlesError.notAuthenticated) {
            try await OpenSubtitlesService.performRenewing(
                session: legacy,
                login: { _, _ in logins += 1; return freshSession() },
                request: { _ -> String in throw OpenSubtitlesError.notAuthenticated }
            )
        }
        #expect(logins == 0)
    }

    @Test func `a changed password reads as signed out`() async {
        await #expect(throws: OpenSubtitlesError.notAuthenticated) {
            try await OpenSubtitlesService.performRenewing(
                session: stored,
                login: { _, _ in throw OpenSubtitlesError.invalidCredentials },
                request: { _ -> String in throw OpenSubtitlesError.notAuthenticated }
            )
        }
    }

    @Test func `other failures are not treated as an expired token`() async {
        var logins = 0
        await #expect(throws: OpenSubtitlesError.quotaExceeded) {
            try await OpenSubtitlesService.performRenewing(
                session: stored,
                login: { _, _ in logins += 1; return freshSession() },
                request: { _ -> String in throw OpenSubtitlesError.quotaExceeded }
            )
        }
        #expect(logins == 0)
    }

    @Test func `a session stored before passwords were kept still decodes`() throws {
        let json = Data(#"{"token":"t","username":"viewer","host":"api.opensubtitles.com","allowedDownloads":20}"#.utf8)
        let session = try JSONDecoder().decode(OpenSubtitlesSession.self, from: json)
        #expect(session.username == "viewer")
        #expect(session.password == nil)
    }
}
