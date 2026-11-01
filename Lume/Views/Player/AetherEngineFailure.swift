//
//  AetherEngineFailure.swift
//  Lume
//
//  Why an AetherEngine stream stopped, read from the engine's stable
//  `PlaybackErrorKind` token and status code, never from its message (which
//  AVFoundation localizes). The engine only classifies; what each cause gets
//  — a fresh stream URL, a slower reconnect, the next engine — is Lume's call.
//

import Foundation

nonisolated enum AetherEngineFailure: String, EngineFailurePolicy {
    /// A dropped connection, a dead source, a pipeline that gave up mid-stream.
    /// Reconnects on the normal schedule.
    case interrupted
    /// A live channel the engine could not revive (`liveSourceReset`): a lost
    /// source, not a fault. Retuned with a fresh load.
    case sourceEnded
    /// HTTP 401 / 403: an expired token, or a connection slot still held by a
    /// previous session.
    case unauthorized
    /// HTTP 429 / 503 / 509 / 5xx: a full connection slot or an overloaded panel.
    case overloaded
    /// HTTP 404 / 410: the stream is gone, and retrying will not bring it back.
    case notFound
    /// The source is fine but this engine cannot serve it: an audio track no
    /// pipeline could carry, a format or route it refuses. Another engine may
    /// play it.
    case unsupported

    /// `kind` is `PlaybackErrorKind.rawValue`; `code` its `underlyingCode`.
    static func classify(kind: String, code: Int?) -> AetherEngineFailure {
        switch kind {
        case "sourceRefused":
            httpFailure(code) ?? .interrupted
        case "sourceRateLimited":
            .overloaded
        case "audioBridgeProducedNoOutput", "dolbyVisionRequiresHardware",
             "demuxedAudioLiveUnsupported", "hlsFormatUnsupported",
             "hlsPlaylistOnRawLivePath", "noPlayableTrackWithinBudget",
             "masterPlaylistRejected", "nativeItemFailed", "softwarePipelineFailed":
            .unsupported
        default:
            .interrupted
        }
    }

    private static func httpFailure(_ code: Int?) -> AetherEngineFailure? {
        guard let code else { return nil }
        return switch code {
        case 401, 403: .unauthorized
        case 404, 410: .notFound
        case 429, 500 ... 599: .overloaded
        default: nil
        }
    }
}
