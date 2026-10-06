//
//  RecordingServerErrorTests.swift
//  LumeTests
//
//  Kit errors map to the app's backend-agnostic cases, and `logDescription`
//  never carries a token, pairing code, URL or server-supplied prose.
//

import Foundation
@testable import Lume
import LumeRecorderKit
import Testing

struct RecordingServerErrorTests {
    @Test(arguments: [
        (LumeRecorderError.unauthorized, RecordingServerError.unauthorized),
        (.notFound, .notFound),
        (.rateLimited, .rateLimited),
        (.insufficientStorage, .insufficientStorage),
        (.conflict(code: LumeRecorderErrorCode.concurrencyLimit, message: "x"), .concurrencyLimit),
        (.conflict(code: LumeRecorderErrorCode.insufficientStorage, message: "x"), .insufficientStorage),
        (.conflict(code: LumeRecorderErrorCode.notPlayable, message: "x"), .notPlayableYet),
        (.conflict(code: "something_else", message: "x"), .conflict(code: "something_else")),
        (.invalidRequest("bad"), .invalidRequest),
        (.server(status: 503, code: nil, message: "down"), .server(status: 503, code: nil)),
        (.transport(URLError(.cannotConnectToHost)), .unreachable(.cannotConnectToHost)),
        (.transport(URLError(.cancelled)), .cancelled),
        (.decoding("nope"), .invalidResponse),
        (.unsupportedAPIVersion(2), .unsupportedAPIVersion(2))
    ])
    func `kit errors map to app cases`(kit: LumeRecorderError, expected: RecordingServerError) {
        #expect(RecordingServerError(kit) == expected)
        #expect(RecordingServerError(kit as any Error) == expected)
    }

    @Test func `foreign errors map sensibly`() {
        #expect(RecordingServerError(URLError(.timedOut)) == .unreachable(.timedOut))
        #expect(RecordingServerError(CancellationError()) == .cancelled)
        #expect(RecordingServerError(RecordingServerError.invalidPairingCode) == .invalidPairingCode)
    }

    @Test func `every case has a user-facing message`() {
        let cases: [RecordingServerError] = [
            .unreachable(.timedOut), .unauthorized, .invalidPairingCode, .rateLimited, .notFound,
            .concurrencyLimit, .insufficientStorage, .notPlayableYet, .conflict(code: "x"),
            .invalidRequest, .server(status: 500, code: nil), .invalidResponse,
            .unsupportedAPIVersion(2), .unsupportedBackend, .invalidAddress, .cancelled
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func `log description drops server prose and unknown codes`() {
        let secret = "http://user:pass@provider.example/live/user/pass/1.ts token=abc123"
        let mapped: [RecordingServerError] = [
            RecordingServerError(LumeRecorderError.conflict(code: secret, message: secret)),
            RecordingServerError(LumeRecorderError.server(status: 500, code: secret, message: secret)),
            RecordingServerError(LumeRecorderError.invalidRequest(secret)),
            RecordingServerError(LumeRecorderError.decoding(secret))
        ]
        for error in mapped {
            #expect(!error.logDescription.contains("pass"))
            #expect(!error.logDescription.contains("://"))
            #expect(!error.logDescription.contains("abc123"))
            #expect(!(error.errorDescription ?? "").contains("abc123"))
        }
        #expect(RecordingServerError.server(status: 500, code: LumeRecorderErrorCode.internalError)
            .logDescription == "HTTP 500 internal_error")
    }

    @Test func `log redaction uses the credential-free summary`() {
        let described = LogRedaction.describe(RecordingServerError.unreachable(.cannotFindHost))
        #expect(described.contains("unreachable"))
        #expect(!described.contains("://"))
    }

    @Test func `endpoint description never shows the token or address`() throws {
        let endpoint = try RecordingServerEndpoint(
            kind: .lumeRecorder, baseURL: #require(URL(string: "http://10.0.0.2:8090")), token: "super-secret-token"
        )
        #expect(!String(describing: endpoint).contains("super-secret-token"))
        #expect(!String(reflecting: endpoint).contains("10.0.0.2"))
        let config = RecordingServerConfig(
            id: UUID(), kindRaw: "lumeRecorder", name: "n", baseURL: "", serverID: nil,
            deviceID: nil, isEnabled: true, updatedAt: .now, endpoint: endpoint
        )
        #expect(!"\(config)".contains("super-secret-token"))
    }
}
