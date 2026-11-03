//
//  HueDiagnostics.swift
//  Lume
//
//  Credential-free renderings of the Hue errors and the bridge address for
//  logs and the diagnostic report. Bridge ids, hosts, application keys,
//  client keys and area ids never appear in either.
//

import Foundation

nonisolated extension HueBridgeError: DiagnosticErrorDescribing {
    var logDescription: String {
        switch self {
        case .linkButtonNotPressed: "link button not pressed"
        case .areaInUse: "area in use"
        case .unauthorized: "unauthorized"
        case .notFound: "not found"
        case .rateLimited: "rate limited"
        case .untrustedCertificate: "untrusted certificate"
        case .wrongBridge: "wrong bridge"
        case let .pairingFailed(type): "pairing failed (type \(type))"
        case .rejected: "rejected"
        case let .server(status): "HTTP \(status)"
        case let .transport(code): "transport \(code.rawValue)"
        case .invalidRequest: "invalid request"
        case .invalidResponse: "invalid response"
        case .cancelled: "cancelled"
        }
    }
}

nonisolated extension HueStreamTransportError: DiagnosticErrorDescribing {
    var logDescription: String {
        switch self {
        case .invalidCredentials: "invalid credentials"
        case .localNetworkDenied: "local network denied"
        case .handshakeFailed: "handshake failed"
        case .timedOut: "timed out"
        case .connectionLost: "connection lost"
        }
    }
}

nonisolated extension HueSyncError: DiagnosticErrorDescribing {
    var logDescription: String {
        switch self {
        case let .bridge(error): "bridge \(error.logDescription)"
        case let .stream(error): "stream \(error.logDescription)"
        case .unsupportedArea: "unsupported area"
        }
    }
}

nonisolated extension HueBridgeAddress: HueRedacted {}
