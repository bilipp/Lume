//
//  RecordingServerTypes.swift
//  Lume
//
//  The app's recording value types, shared by every recording-server backend.
//  Each backend maps its own wire DTOs into these, so the UI and the pure
//  recording helpers never depend on one server's client.
//

import Foundation

/// A recording's id on its server. LumeRecorder ids are `UUID.uuidString`, so
/// the `recordingProgress.<id>` resume keys stay the ones earlier builds wrote.
nonisolated struct RecordingID: RawRepresentable, Hashable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ uuid: UUID) {
        rawValue = uuid.uuidString
    }

    /// The UUID a LumeRecorder id was made from; `nil` for any other backend's.
    var uuid: UUID? {
        UUID(uuidString: rawValue)
    }

    var description: String {
        rawValue
    }
}

/// Lifecycle state of a recording. A state this build doesn't know is kept as
/// `.unknown(rawValue)`.
nonisolated enum ServerRecordingStatus: Hashable, CustomStringConvertible {
    case scheduled
    case recording
    case completed
    case failed
    case cancelled
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "scheduled": self = .scheduled
        case "recording": self = .recording
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .scheduled: "scheduled"
        case .recording: "recording"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case let .unknown(raw): raw
        }
    }

    /// `scheduled` or `recording`: the server still has work to do.
    var isPending: Bool {
        self == .scheduled || self == .recording
    }

    var description: String {
        rawValue
    }
}

nonisolated struct ServerRecording: Hashable, Identifiable {
    var id: RecordingID
    var title: String
    var channelName: String?
    var channelLogoURL: URL?
    var programmeDescription: String?
    /// The `RecordingSourceRef` raw value Lume sent; `nil` for a recording made
    /// outside Lume.
    var sourceRef: String?
    var start: Date
    var end: Date
    var status: ServerRecordingStatus
    var failureReason: String?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    /// Media duration recorded so far, in seconds.
    var durationSeconds: Double?
    var sizeBytes: Int64?
    /// Completed, but ended before its scheduled end (stopped or interrupted).
    var isPartial: Bool
    /// The end of the programme the recording was planned from, for a server
    /// that pads `end` itself; `nil` when the server reports none.
    var programmeEnd: Date?

    init(
        id: RecordingID,
        title: String,
        channelName: String? = nil,
        channelLogoURL: URL? = nil,
        programmeDescription: String? = nil,
        sourceRef: String? = nil,
        start: Date,
        end: Date,
        status: ServerRecordingStatus,
        failureReason: String? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        durationSeconds: Double? = nil,
        sizeBytes: Int64? = nil,
        isPartial: Bool = false,
        programmeEnd: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.channelName = channelName
        self.channelLogoURL = channelLogoURL
        self.programmeDescription = programmeDescription
        self.sourceRef = sourceRef
        self.start = start
        self.end = end
        self.status = status
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.isPartial = isPartial
        self.programmeEnd = programmeEnd
    }
}

/// Who the server is, for the Settings version line and the pairing's identity.
nonisolated struct ServerIdentity: Hashable {
    var id: UUID
    var name: String
    var version: String
}

/// Load figures for the Settings status section. A backend that doesn't report
/// disk space leaves it `nil`.
nonisolated struct RecordingServerStatus: Hashable {
    var activeRecordings: Int
    var scheduledRecordings: Int
    var freeDiskBytes: Int64?
    var totalDiskBytes: Int64?
}

/// What a backend supports beyond recording itself, and how it records, so
/// callers ask this instead of branching on the backend kind.
nonisolated struct RecordingServerCapabilities: Hashable {
    /// Reports free and total disk space.
    var diskStatus: Bool
    /// Has a load endpoint; without one the store counts the recordings list.
    var hasStatusEndpoint: Bool
    /// Pairs by a one-time code from the server.
    var codePairing: Bool
    /// Can revoke this device's access when the server is removed.
    var deviceRevoke: Bool
    /// The account may list and play recordings but not create, stop or delete them.
    var readOnly: Bool
    /// Cancelling a schedule deletes it, so a schedule offers no separate Delete.
    var cancelDeletes: Bool
    /// Lists recordings made on the server itself, which nothing ties to a
    /// channel a profile may see.
    var listsExternalRecordings: Bool
    /// Who pads a recording's window.
    var padding: RecordingRequestPlanner.Padding
    /// Schedules any channel it records. Otherwise only a playlist kind whose
    /// stream URLs don't expire can schedule.
    var schedulesAnySource: Bool
    var cancelRule: RecordingCancelRule
    var deleteWording: RecordingDeleteWording

    static let lumeRecorder = RecordingServerCapabilities(
        diskStatus: true,
        hasStatusEndpoint: true,
        codePairing: true,
        deviceRevoke: true,
        readOnly: false,
        cancelDeletes: false,
        listsExternalRecordings: false,
        padding: .lume,
        schedulesAnySource: false,
        cancelRule: .untilCapturing,
        deleteWording: .allDevices
    )

    /// Before the account's permissions are read; `readOnly` comes from
    /// `RecordingServerBackend.accountCapabilities()`. Dispatcharr records its
    /// own channels, so no stream URL can expire before a schedule starts.
    static let dispatcharr = RecordingServerCapabilities(
        diskStatus: false,
        hasStatusEndpoint: false,
        codePairing: false,
        deviceRevoke: false,
        readOnly: false,
        cancelDeletes: true,
        listsExternalRecordings: true,
        padding: .server,
        schedulesAnySource: true,
        cancelRule: .whileScheduled,
        deleteWording: .dispatcharr
    )

    /// Whether ending `recording` cancels it rather than stopping it.
    func cancelsRatherThanStops(_ recording: ServerRecording, now: Date) -> Bool {
        switch cancelRule {
        case .untilCapturing: !RecordingRequestPlanner.isCapturing(recording, now: now)
        case .whileScheduled: recording.status == .scheduled
        }
    }
}

/// When ending a pending recording cancels it rather than stopping it.
nonisolated enum RecordingCancelRule: Hashable {
    /// Until capture starts: a schedule whose window has opened already
    /// reads Stop (LumeRecorder).
    case untilCapturing
    /// While the server hasn't started it, since ending one deletes whatever
    /// hasn't started yet (Dispatcharr).
    case whileScheduled
}

/// Where a delete confirmation says the video goes.
nonisolated enum RecordingDeleteWording: Hashable {
    /// Removed from the recording server for every paired device.
    case allDevices
    /// Deleted from the user's Dispatcharr server; a running one stops first.
    case dispatcharr
}

nonisolated extension RecordingServerKind {
    /// What every account on a server of this kind can do, before its own
    /// permissions are read.
    var capabilities: RecordingServerCapabilities {
        switch self {
        case .lumeRecorder: .lumeRecorder
        case .dispatcharr: .dispatcharr
        }
    }
}

/// Where and how to play one recording. `httpHeaders` carry any credential the
/// URL needs; the URL itself may be short-lived, so neither is ever persisted
/// or logged.
nonisolated struct RecordingPlayback: Hashable {
    var url: URL
    var httpHeaders: [String: String]

    init(url: URL, httpHeaders: [String: String] = [:]) {
        self.url = url
        self.httpHeaders = httpHeaders
    }
}

/// A LumeRecorder device pairing: the token, this device's id on the server,
/// and who the server is.
nonisolated struct RecordingServerPairing: Hashable {
    var token: String
    var deviceID: UUID
    var server: ServerIdentity
}

/// What the server records from: the provider stream URL itself, or a channel
/// the server already knows by its own id.
nonisolated enum RecordingCreateTarget: Hashable {
    case streamURL(URL)
    case dispatcharrChannel(Int)
}

nonisolated struct RecordingCreateRequest: Hashable {
    var target: RecordingCreateTarget
    var title: String
    var channelName: String?
    var channelLogoURL: URL?
    var programmeDescription: String?
    var start: Date
    var end: Date
    var sourceRef: String?
    /// The EPG programme being recorded; `nil` for a fixed-duration
    /// record-now, which has no programme to describe.
    var programme: DateInterval?

    init(
        target: RecordingCreateTarget,
        title: String,
        channelName: String? = nil,
        channelLogoURL: URL? = nil,
        programmeDescription: String? = nil,
        start: Date,
        end: Date,
        sourceRef: String? = nil,
        programme: DateInterval? = nil
    ) {
        self.target = target
        self.title = title
        self.channelName = channelName
        self.channelLogoURL = channelLogoURL
        self.programmeDescription = programmeDescription
        self.start = start
        self.end = end
        self.sourceRef = sourceRef
        self.programme = programme
    }
}
