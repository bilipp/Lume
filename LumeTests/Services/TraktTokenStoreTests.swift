import Foundation
@testable import Lume
import Testing

// MARK: - TraktTokens (pure logic)

struct TraktTokensTests {
    private func makeTokens(
        accessToken: String = "access",
        refreshToken: String = "refresh",
        createdAt: TimeInterval = 1000,
        expiresIn: TimeInterval = 500,
        scope: String? = "public",
        tokenType: String? = "Bearer"
    ) -> TraktTokens {
        TraktTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            createdAt: createdAt,
            expiresIn: expiresIn,
            scope: scope,
            tokenType: tokenType
        )
    }

    @Test func `expiry date is created plus lifetime`() {
        let tokens = makeTokens(createdAt: 1000, expiresIn: 500)
        #expect(tokens.expiryDate == Date(timeIntervalSince1970: 1500))
    }

    @Test func `needs refresh when already expired`() {
        let createdAt = Date().timeIntervalSince1970 - 100 * 24 * 60 * 60
        let tokens = makeTokens(createdAt: createdAt, expiresIn: 90 * 24 * 60 * 60)
        #expect(tokens.needsRefresh == true)
    }

    @Test func `needs refresh when within a day of expiry`() {
        // Expires in 12 hours — inside the one-day refresh window.
        let createdAt = Date().timeIntervalSince1970
        let tokens = makeTokens(createdAt: createdAt, expiresIn: 12 * 60 * 60)
        #expect(tokens.needsRefresh == true)
    }

    @Test func `does not need refresh when far from expiry`() {
        // Fresh three-month token — well outside the refresh window.
        let createdAt = Date().timeIntervalSince1970
        let tokens = makeTokens(createdAt: createdAt, expiresIn: 90 * 24 * 60 * 60)
        #expect(tokens.needsRefresh == false)
    }

    @Test func `codable round trip preserves values`() throws {
        let tokens = makeTokens()
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(TraktTokens.self, from: data)
        #expect(decoded == tokens)
    }

    @Test func `codable round trip with nil metadata`() throws {
        let tokens = makeTokens(scope: nil, tokenType: nil)
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(TraktTokens.self, from: data)
        #expect(decoded == tokens)
        #expect(decoded.scope == nil)
        #expect(decoded.tokenType == nil)
    }

    @Test func `equatable distinguishes different tokens`() {
        let base = makeTokens()
        #expect(base != makeTokens(accessToken: "different"))
        #expect(base != makeTokens(refreshToken: "different"))
        #expect(base != makeTokens(expiresIn: 999))
        #expect(base == makeTokens())
    }
}

// MARK: - TraktTokenStore (keychain)

/// Serialized because every test touches the single shared keychain item
/// (service + account are constant), so concurrent runs would race.
@Suite(.serialized)
struct TraktTokenStoreTests {
    init() {
        // Start every test from a known-empty keychain slot.
        TraktTokenStore.clear()
    }

    private func makeTokens(accessToken: String = "access-token") -> TraktTokens {
        TraktTokens(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            createdAt: 1_700_000_000,
            expiresIn: 7_776_000,
            scope: "public",
            tokenType: "Bearer"
        )
    }

    @Test func `load returns nil when nothing stored`() {
        #expect(TraktTokenStore.load() == nil)
    }

    @Test func `save then load returns the same tokens`() {
        let tokens = makeTokens()
        #expect(TraktTokenStore.save(tokens) == true)
        #expect(TraktTokenStore.load() == tokens)
        TraktTokenStore.clear()
    }

    @Test func `save overwrites an existing token set`() {
        #expect(TraktTokenStore.save(makeTokens(accessToken: "first")) == true)
        // Second save exercises the SecItemUpdate path.
        let updated = makeTokens(accessToken: "second")
        #expect(TraktTokenStore.save(updated) == true)
        #expect(TraktTokenStore.load() == updated)
        TraktTokenStore.clear()
    }

    @Test func `clear removes stored tokens`() {
        #expect(TraktTokenStore.save(makeTokens()) == true)
        #expect(TraktTokenStore.clear() == true)
        #expect(TraktTokenStore.load() == nil)
    }

    @Test func `clear succeeds when nothing is stored`() {
        // A missing item is the desired end state, so this reports success.
        #expect(TraktTokenStore.clear() == true)
    }
}
