import Foundation
@testable import Lume
import Testing

/// Deliberately strict decoding fixtures (no lenient coercion) so a type
/// mismatch can be provoked to exercise `XtreamError.logDescription`.
private struct StrictUserInfoFixture: Decodable {
    let expDate: String?

    enum CodingKeys: String, CodingKey {
        case expDate = "exp_date"
    }
}

private struct StrictAuthFixture: Decodable {
    let userInfo: StrictUserInfoFixture

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
    }
}

struct XtreamErrorTests {
    // MARK: - XtreamError

    @Test func `error invalid url`() {
        let error = XtreamError.invalidURL
        #expect(error.errorDescription?.contains("URL") == true)
        #expect(error.isRetriable == false)
        #expect(error.isAuthFailure == false)
    }

    @Test func `error authentication failed`() {
        let error = XtreamError.authenticationFailed
        #expect(error.errorDescription?.contains("Authentication") == true)
        #expect(error.isRetriable == false)
        #expect(error.isAuthFailure == true)
    }

    @Test func `error network error`() {
        let underlying = URLError(.notConnectedToInternet)
        let error = XtreamError.networkError(underlying)
        #expect(error.errorDescription?.contains("Network") == true)
        #expect(error.isRetriable == true)
        #expect(error.isAuthFailure == false)
    }

    @Test func `error decoding error`() {
        let underlying = NSError(domain: "test", code: 0)
        let error = XtreamError.decodingError(underlying)
        #expect(error.errorDescription?.contains("Failed to read") == true)
        #expect(error.isRetriable == false)
    }

    @Test func `error invalid response`() {
        let error = XtreamError.invalidResponse
        #expect(error.errorDescription?.contains("invalid") == true)
        #expect(error.isRetriable == false)
    }

    @Test func `error server error 4xx not retriable`() {
        let error = XtreamError.serverError(429)
        #expect(error.errorDescription?.contains("429") == true)
        #expect(error.isRetriable == false)
    }

    @Test func `error server error 5xx retriable`() {
        let error = XtreamError.serverError(502)
        #expect(error.errorDescription?.contains("502") == true)
        #expect(error.isRetriable == true)
    }

    // MARK: - Decoding-error log descriptions

    @Test func `decoding log description includes coding path for type mismatch`() throws {
        let json = Data("""
        {"user_info": {"exp_date": 1770000000}, "server_info": {}}
        """.utf8)
        do {
            _ = try JSONDecoder().decode(StrictAuthFixture.self, from: json)
            Issue.record("expected a type mismatch")
        } catch {
            let description = XtreamError.decodingError(error).logDescription
            #expect(description.contains("type mismatch"))
            #expect(description.contains("user_info.exp_date"))
        }
    }

    @Test func `decoding log description names array root and missing keys`() {
        do {
            _ = try JSONDecoder().decode([XtreamCategory].self, from: Data("{\"k\": 1}".utf8))
        } catch {
            let description = XtreamError.decodingError(error).logDescription
            #expect(description.contains("type mismatch"))
            #expect(description.contains("response root"))
        }

        do {
            _ = try JSONDecoder().decode(XtreamAuthResponse.self, from: Data("{}".utf8))
        } catch {
            let description = XtreamError.decodingError(error).logDescription
            #expect(description.contains("missing key"))
            #expect(description.contains("user_info"))
        }
    }

    @Test func `decoding log description never contains values`() {
        // The path renderer must emit key names and indexes only.
        do {
            _ = try JSONDecoder().decode(
                [XtreamCategory].self,
                from: Data("[{\"category_id\": \"1\", \"category_name\": \"x\"}, \"secret\"]".utf8)
            )
        } catch {
            let description = XtreamError.decodingError(error).logDescription
            #expect(!description.contains("secret"))
            #expect(description.contains("[1]"))
        }
    }

    // MARK: - StreamFormat

    @Test func `stream format raw values`() {
        #expect(StreamFormat.m3u8.rawValue == "m3u8")
        #expect(StreamFormat.tsStream.rawValue == "ts")
    }

    // MARK: - SyncError

    @Test func `sync error descriptions`() {
        #expect(SyncError.syncInProgress.errorDescription?.contains("already in progress") == true)
        #expect(SyncError.playlistNotFound.errorDescription?.contains("not be found") == true)
        #expect(SyncError.invalidCredentials.errorDescription?.contains("Invalid") == true)
        #expect(SyncError.networkError(URLError(.timedOut)).errorDescription?.contains("Network") == true)
        #expect(SyncError.databaseError(NSError(domain: "db", code: 1)).errorDescription?.contains("Database") == true)
    }
}
