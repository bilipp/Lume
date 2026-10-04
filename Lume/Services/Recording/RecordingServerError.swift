//
//  RecordingServerError.swift
//  Lume
//
//  The one error type app code sees from any recording-server backend, with
//  localized messages for the UI and a credential-free `logDescription` for the
//  diagnostic journal. Server-supplied messages are deliberately not carried:
//  they are unlocalized and nothing guarantees they are free of a URL.
//

import Foundation
import LumeRecorderKit

nonisolated enum RecordingServerError: LocalizedError, Equatable {
    /// No HTTP response at all: offline, refused, DNS, timeout.
    case unreachable(URLError.Code)
    /// The stored token was revoked or never valid; the device must pair again.
    case unauthorized
    case invalidPairingCode
    case rateLimited
    case notFound
    case concurrencyLimit
    case insufficientStorage
    /// The recording exists but has no media segment to play yet.
    case notPlayableYet
    case conflict(code: String)
    case invalidRequest
    case server(status: Int, code: String?)
    case invalidResponse
    case unsupportedAPIVersion(Int)
    /// A synced config whose backend kind this build doesn't know.
    case unsupportedBackend
    /// A typed address that isn't a plausible http(s) host.
    case invalidAddress
    case cancelled

    init(_ error: any Error) {
        switch error {
        case let error as RecordingServerError:
            self = error
        case let error as LumeRecorderError:
            self.init(error)
        case let error as URLError:
            self = .transport(error.code)
        case is CancellationError:
            self = .cancelled
        default:
            self = .invalidResponse
        }
    }

    init(_ error: LumeRecorderError) {
        switch error {
        case .unauthorized:
            self = .unauthorized
        case .notFound:
            self = .notFound
        case let .conflict(code, _):
            self = .conflict(code)
        case .rateLimited:
            self = .rateLimited
        case .insufficientStorage:
            self = .insufficientStorage
        case .invalidRequest:
            self = .invalidRequest
        case let .server(status, code, _):
            self = .server(status: status, code: code)
        case let .transport(urlError):
            self = .transport(urlError.code)
        case .decoding:
            self = .invalidResponse
        case let .unsupportedAPIVersion(version):
            self = .unsupportedAPIVersion(version)
        }
    }

    private static func conflict(_ code: String) -> RecordingServerError {
        switch code {
        case LumeRecorderErrorCode.concurrencyLimit: .concurrencyLimit
        case LumeRecorderErrorCode.insufficientStorage: .insufficientStorage
        case LumeRecorderErrorCode.notPlayable: .notPlayableYet
        default: .conflict(code: code)
        }
    }

    private static func transport(_ code: URLError.Code) -> RecordingServerError {
        code == .cancelled ? .cancelled : .unreachable(code)
    }

    var errorDescription: String? {
        switch self {
        case .unreachable:
            String(localized: "Couldn't reach the recording server. Check that it's running and on the same network.")
        case .unauthorized:
            String(localized: "This device is no longer paired with the recording server. Pair it again in Settings.")
        case .invalidPairingCode:
            String(localized: "That pairing code is wrong or has expired. Check the code the recording server shows.")
        case .rateLimited:
            String(localized: "Too many pairing attempts. Try again in a minute.")
        case .notFound:
            String(localized: "This recording no longer exists on the server.")
        case .concurrencyLimit:
            String(localized: "The recording server is already recording as many streams as it allows. Stop another recording and try again.")
        case .insufficientStorage:
            String(localized: "The recording server is out of disk space. Delete some recordings and try again.")
        case .notPlayableYet:
            String(localized: "This recording hasn't captured any video yet. Try again in a few seconds.")
        case .conflict:
            String(localized: "The recording server can't do that right now.")
        case .invalidRequest:
            String(localized: "The recording server rejected the request.")
        case let .server(status, _):
            String(localized: "The recording server reported an error (HTTP \(status)).")
        case .invalidResponse:
            String(localized: "The recording server sent a response Lume couldn't read.")
        case .unsupportedAPIVersion:
            String(localized: "This recording server uses a different API version. Update Lume and the server to their latest versions.")
        case .unsupportedBackend:
            String(localized: "This version of Lume doesn't support this type of recording server.")
        case .invalidAddress:
            String(localized: "Enter a valid server address, such as 192.168.1.20:\(String(LumeRecorderClient.defaultPort)).")
        case .cancelled:
            String(localized: "The request was cancelled.")
        }
    }

    /// Safe for `privacy: .public`: no token, pairing code, URL or server prose —
    /// only case names, status codes and the server's machine-readable code when
    /// it is one this build knows.
    var logDescription: String {
        switch self {
        case let .unreachable(code):
            "unreachable (\(NSURLErrorDomain) \(code.rawValue))"
        case .unauthorized:
            "HTTP 401 (token rejected)"
        case .invalidPairingCode:
            "HTTP 401 (pairing code rejected)"
        case .rateLimited:
            "HTTP 429 (pairing rate limited)"
        case .notFound:
            "HTTP 404"
        case .concurrencyLimit:
            "HTTP 409 \(LumeRecorderErrorCode.concurrencyLimit)"
        case .insufficientStorage:
            "insufficient storage"
        case .notPlayableYet:
            "HTTP 409 \(LumeRecorderErrorCode.notPlayable)"
        case let .conflict(code):
            "HTTP 409 \(Self.knownCode(code))"
        case .invalidRequest:
            "HTTP 400"
        case let .server(status, code):
            "HTTP \(status) \(Self.knownCode(code))"
        case .invalidResponse:
            "undecodable response"
        case let .unsupportedAPIVersion(version):
            "unsupported API version \(version)"
        case .unsupportedBackend:
            "unsupported backend kind"
        case .invalidAddress:
            "invalid server address"
        case .cancelled:
            "cancelled"
        }
    }

    private static let knownCodes: Set<String> = [
        LumeRecorderErrorCode.unauthorized, LumeRecorderErrorCode.pairingInvalid,
        LumeRecorderErrorCode.rateLimited, LumeRecorderErrorCode.invalidRequest,
        LumeRecorderErrorCode.notFound, LumeRecorderErrorCode.concurrencyLimit,
        LumeRecorderErrorCode.insufficientStorage, LumeRecorderErrorCode.notPlayable,
        LumeRecorderErrorCode.forbidden, LumeRecorderErrorCode.internalError
    ]

    private static func knownCode(_ code: String?) -> String {
        guard let code else { return "(no code)" }
        return knownCodes.contains(code) ? code : "(other code)"
    }
}

nonisolated extension RecordingServerError: DiagnosticErrorDescribing {}
