import Foundation
@testable import Lume
import Testing

struct APIClientTests {
    // MARK: - HTTPMethod

    @Test func httpMethodRawValues() {
        #expect(HTTPMethod.get.rawValue == "GET")
        #expect(HTTPMethod.post.rawValue == "POST")
        #expect(HTTPMethod.put.rawValue == "PUT")
        #expect(HTTPMethod.patch.rawValue == "PATCH")
        #expect(HTTPMethod.delete.rawValue == "DELETE")
    }

    // MARK: - Endpoint asURLRequest

    @Test func endpointBuildsBasicURL() throws {
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com")),
            path: "/api/test",
            method: .get
        )
        let request = try endpoint.asURLRequest()
        #expect(request.url?.absoluteString == "http://example.com/api/test")
        #expect(request.httpMethod == "GET")
    }

    @Test func endpointWithoutLeadingSlash() throws {
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com/api")),
            path: "test",
            method: .get
        )
        let request = try endpoint.asURLRequest()
        #expect(request.url?.absoluteString == "http://example.com/api/test")
    }

    @Test func endpointWithTrailingSlashOnBase() throws {
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com/api/")),
            path: "/test",
            method: .get
        )
        let request = try endpoint.asURLRequest()
        #expect(request.url?.absoluteString == "http://example.com/api//test")
    }

    @Test func endpointWithQueryItems() throws {
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com")),
            path: "/search",
            method: .get,
            queryItems: [
                URLQueryItem(name: "q", value: "test"),
                URLQueryItem(name: "limit", value: "10"),
            ]
        )
        let request = try endpoint.asURLRequest()
        let urlString = try #require(request.url?.absoluteString)
        #expect(urlString.contains("q=test"))
        #expect(urlString.contains("limit=10"))
    }

    @Test func endpointWithHeaders() throws {
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com")),
            path: "/auth",
            method: .get,
            headers: ["Authorization": "Bearer token123"]
        )
        let request = try endpoint.asURLRequest()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token123")
    }

    @Test func endpointWithBody() throws {
        let body = try JSONSerialization.data(withJSONObject: ["key": "value"])
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com")),
            path: "/submit",
            method: .post,
            body: body
        )
        let request = try endpoint.asURLRequest()
        #expect(request.httpBody == body)
    }

    @Test func endpointDefaultTimeout() throws {
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com")),
            path: "/test",
            method: .get
        )
        let request = try endpoint.asURLRequest()
        #expect(request.timeoutInterval == 60)
    }

    @Test func endpointCustomTimeout() throws {
        let endpoint = try TestEndpoint(
            baseURL: #require(URL(string: "http://example.com")),
            path: "/test",
            method: .get,
            timeout: 120
        )
        let request = try endpoint.asURLRequest()
        #expect(request.timeoutInterval == 120)
    }

    // MARK: - NetworkError

    @Test func networkErrorDescriptions() {
        #expect(NetworkError.invalidURL.errorDescription == "The URL is invalid")
        #expect(NetworkError.noConnection.errorDescription == "No internet connection")
        #expect(NetworkError.invalidResponse.errorDescription == "Invalid response from server")
        #expect(NetworkError.authenticationFailed.errorDescription == "Authentication failed. Please check your credentials.")
    }

    @Test func networkErrorServerErrorMessage() {
        let error = NetworkError.serverError(500)
        #expect(error.errorDescription?.contains("500") == true)
    }

    @Test func networkErrorDecodingMessage() {
        let error = NetworkError.decodingError(NSError(domain: "test", code: 1))
        #expect(error.errorDescription?.contains("Failed to decode") == true)
    }

    // MARK: - Retriable

    @Test func retriableErrors() {
        #expect(NetworkError.noConnection.isRetriable == true)
        #expect(NetworkError.timeout.isRetriable == true)
        #expect(NetworkError.rateLimited(retryAfter: 10).isRetriable == true)
        #expect(NetworkError.serverError(502).isRetriable == true)
    }

    @Test func nonRetriableErrors() {
        #expect(NetworkError.invalidURL.isRetriable == false)
        #expect(NetworkError.authenticationFailed.isRetriable == false)
        #expect(NetworkError.invalidResponse.isRetriable == false)
        #expect(NetworkError.decodingError(NSError(domain: "test", code: 0, userInfo: nil)).isRetriable == false)
        #expect(NetworkError.serverError(400).isRetriable == false)
        #expect(NetworkError.unknown.isRetriable == false)
    }

    // MARK: - RetryBackoff

    @Test func linearBackoff() {
        let backoff = RetryBackoff.linear
        #expect(backoff.delay(for: 1) == 1)
        #expect(backoff.delay(for: 2) == 2)
        #expect(backoff.delay(for: 3) == 3)
    }

    @Test func exponentialBackoff() {
        let backoff = RetryBackoff.exponential
        #expect(backoff.delay(for: 1) == 2)
        #expect(backoff.delay(for: 2) == 4)
        #expect(backoff.delay(for: 3) == 8)
        #expect(backoff.delay(for: 4) == 16)
    }

    // MARK: - RetryBackoff additional

    @Test func exponentialBackoffIncreases() {
        let backoff = RetryBackoff.exponential
        #expect(backoff.delay(for: 1) < backoff.delay(for: 2))
        #expect(backoff.delay(for: 2) < backoff.delay(for: 3))
    }

    @Test func linearBackoffIncreases() {
        let backoff = RetryBackoff.linear
        #expect(backoff.delay(for: 1) < backoff.delay(for: 2))
        #expect(backoff.delay(for: 2) < backoff.delay(for: 3))
    }

    // MARK: - Test Endpoint

    private struct TestEndpoint: Endpoint {
        var baseURL: URL
        var path: String
        var method: HTTPMethod
        var headers: [String: String]?
        var queryItems: [URLQueryItem]?
        var body: Data?
        var timeout: TimeInterval = 60
    }
}
