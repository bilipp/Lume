import Foundation
@testable import Lume
import Testing

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
