//
//  RecordingServerTypes+LumeRecorder.swift
//  Lume
//
//  Maps LumeRecorderKit's wire DTOs to the app's recording value types and
//  back. The only file outside the LumeRecorder backend that needs both.
//

import Foundation
import LumeRecorderKit

nonisolated extension ServerRecordingStatus {
    init(_ status: RecordingStatus) {
        self.init(rawValue: status.rawValue)
    }
}

nonisolated extension ServerRecording {
    init(_ recording: Recording) {
        self.init(
            id: RecordingID(recording.id),
            title: recording.title,
            channelName: recording.channelName,
            channelLogoURL: recording.channelLogoURL,
            programmeDescription: recording.programmeDescription,
            sourceRef: recording.sourceRef,
            start: recording.start,
            end: recording.end,
            status: ServerRecordingStatus(recording.status),
            failureReason: recording.failureReason,
            createdAt: recording.createdAt,
            startedAt: recording.startedAt,
            finishedAt: recording.finishedAt,
            durationSeconds: recording.durationSeconds,
            sizeBytes: recording.sizeBytes
        )
    }
}

nonisolated extension ServerIdentity {
    init(_ info: ServerInfo) {
        self.init(id: info.id, name: info.name, version: info.version)
    }
}

nonisolated extension RecordingServerPairing {
    init(_ response: PairResponse) {
        self.init(token: response.token, deviceID: response.deviceID, server: ServerIdentity(response.server))
    }
}

nonisolated extension RecordingServerStatus {
    init(_ status: ServerStatus) {
        self.init(
            activeRecordings: status.activeRecordings,
            scheduledRecordings: status.scheduledRecordings,
            freeDiskBytes: status.freeDiskBytes,
            totalDiskBytes: status.totalDiskBytes
        )
    }
}

nonisolated extension RecordingPlayback {
    /// A grant's URL is path-signed, so it needs no headers.
    init(_ grant: PlaybackGrant) {
        self.init(url: grant.url)
    }
}

nonisolated extension CreateRecordingRequest {
    /// `nil` for a target LumeRecorder can't record: it only takes stream URLs.
    init?(_ request: RecordingCreateRequest) {
        guard case let .streamURL(streamURL) = request.target else { return nil }
        self.init(
            streamURL: streamURL,
            title: request.title,
            channelName: request.channelName,
            channelLogoURL: request.channelLogoURL,
            programmeDescription: request.programmeDescription,
            start: request.start,
            end: request.end,
            sourceRef: request.sourceRef
        )
    }
}
