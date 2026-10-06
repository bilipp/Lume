//
//  RecordingRequestPlanner.swift
//  Lume
//
//  The recording rules, kept free of networking and SwiftData so every entry
//  point (channel menu, EPG detail, Guide hub, player) plans a recording the
//  same way: the record-now and schedule windows with their padding, the
//  `sourceRef` that ties a server recording back to its channel, the
//  idempotency key for one user action, and parental filtering.
//

import Foundation
import LumeRecorderKit

/// Identifies the catalog channel a recording was made from. Travels to the
/// server as the opaque `sourceRef` string `"<playlistUUID>:live:<streamID>"`,
/// where `streamID` is the channel's catalog `LiveStream.id`.
nonisolated struct RecordingSourceRef: Hashable {
    private static let liveMarker = "live"

    let playlistID: UUID
    let streamID: String

    init(playlistID: UUID, streamID: String) {
        self.playlistID = playlistID
        self.streamID = streamID
    }

    init(stream: LiveStream, playlist: Playlist) {
        self.init(playlistID: playlist.id, streamID: stream.id)
    }

    /// `nil` for anything that isn't a well-formed live reference — a
    /// recording made by another client, or a future reference kind.
    init?(rawValue: String) {
        // The stream id is the last component and may itself contain colons.
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let playlistID = UUID(uuidString: String(parts[0])),
              parts[1] == Self.liveMarker,
              !parts[2].isEmpty
        else { return nil }
        self.init(playlistID: playlistID, streamID: String(parts[2]))
    }

    var rawValue: String {
        "\(playlistID.uuidString):\(Self.liveMarker):\(streamID)"
    }
}

nonisolated enum RecordingRequestPlanner {
    /// Lead time before a scheduled programme's listed start.
    static let schedulePreRoll: TimeInterval = 2 * 60
    /// Tail after a programme's listed end, for record-now and scheduled alike.
    static let postRoll: TimeInterval = 5 * 60

    /// What record-now offers when the channel has no guide data.
    enum FallbackDuration: Int, CaseIterable, Identifiable {
        case thirtyMinutes = 30
        case oneHour = 60
        case twoHours = 120

        var id: Int {
            rawValue
        }

        var interval: TimeInterval {
            TimeInterval(rawValue) * 60
        }
    }

    /// The guide programme a recording is planned from.
    struct Programme: Hashable {
        let title: String
        let description: String?
        let start: Date
        let end: Date

        init(title: String, description: String? = nil, start: Date, end: Date) {
            self.title = title
            self.description = description
            self.start = start
            self.end = end
        }
    }

    /// The channel being recorded, as the server should label it.
    struct Channel: Hashable {
        let name: String
        let logoURL: URL?
        let sourceRef: RecordingSourceRef

        init(name: String, logoURL: URL? = nil, sourceRef: RecordingSourceRef) {
            self.name = name
            self.logoURL = logoURL
            self.sourceRef = sourceRef
        }
    }

    enum ProgrammeTiming: Hashable {
        /// On air: offer Record.
        case live
        /// Not started yet: offer Schedule Recording.
        case upcoming
        /// Over: nothing to record.
        case ended
    }

    /// A ready-to-send request plus the key that makes re-sending it safe.
    /// Built once per user action and reused for any re-send of that action.
    struct Plan: Hashable {
        let request: CreateRecordingRequest
        let idempotencyKey: String
    }

    // MARK: - Timing

    static func timing(of programme: Programme, now: Date) -> ProgrammeTiming {
        if programme.end <= now { return .ended }
        return programme.start > now ? .upcoming : .live
    }

    /// Record-now from the airing programme: now until its end plus the
    /// post-roll. `nil` when there is no programme on air, which is the
    /// caller's cue to offer a `FallbackDuration`.
    static func recordNowWindow(programme: Programme?, now: Date) -> DateInterval? {
        guard let programme, timing(of: programme, now: now) == .live else { return nil }
        return DateInterval(start: now, end: programme.end.addingTimeInterval(postRoll))
    }

    static func recordNowWindow(duration: FallbackDuration, now: Date) -> DateInterval {
        DateInterval(start: now, duration: duration.interval)
    }

    static func scheduleWindow(programme: Programme) -> DateInterval {
        DateInterval(
            start: programme.start.addingTimeInterval(-schedulePreRoll),
            end: programme.end.addingTimeInterval(postRoll)
        )
    }

    // MARK: - Requests

    /// `nil` when no programme is on air; ask for a `FallbackDuration` instead.
    static func recordNow(
        streamURL: URL,
        channel: Channel,
        programme: Programme?,
        now: Date,
        actionID: UUID = UUID()
    ) -> Plan? {
        guard let window = recordNowWindow(programme: programme, now: now) else { return nil }
        return plan(streamURL: streamURL, channel: channel, programme: programme, window: window, actionID: actionID)
    }

    static func recordNow(
        streamURL: URL,
        channel: Channel,
        duration: FallbackDuration,
        now: Date,
        actionID: UUID = UUID()
    ) -> Plan {
        plan(
            streamURL: streamURL,
            channel: channel,
            programme: nil,
            window: recordNowWindow(duration: duration, now: now),
            actionID: actionID
        )
    }

    /// `nil` unless the programme is still upcoming — an airing one is
    /// recorded now instead.
    static func schedule(
        streamURL: URL,
        channel: Channel,
        programme: Programme,
        now: Date,
        actionID: UUID = UUID()
    ) -> Plan? {
        guard timing(of: programme, now: now) == .upcoming else { return nil }
        return plan(
            streamURL: streamURL,
            channel: channel,
            programme: programme,
            window: scheduleWindow(programme: programme),
            actionID: actionID
        )
    }

    /// The programme title, else the channel name.
    static func title(programme: Programme?, channel: Channel) -> String {
        let programmeTitle = programme?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return programmeTitle.isEmpty ? channel.name : programmeTitle
    }

    /// One key per user action: the same action re-sent yields the same key, so
    /// the server returns the recording it already created.
    static func idempotencyKey(for actionID: UUID) -> String {
        actionID.uuidString.lowercased()
    }

    private static func plan(
        streamURL: URL,
        channel: Channel,
        programme: Programme?,
        window: DateInterval,
        actionID: UUID
    ) -> Plan {
        let description = programme?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateRecordingRequest(
            streamURL: streamURL,
            title: title(programme: programme, channel: channel),
            channelName: channel.name,
            channelLogoURL: channel.logoURL,
            programmeDescription: description?.isEmpty == false ? description : nil,
            start: window.start,
            end: window.end,
            sourceRef: channel.sourceRef.rawValue
        )
        return Plan(request: request, idempotencyKey: idempotencyKey(for: actionID))
    }

    // MARK: - Matching

    /// Whether `recording` is capturing right now: running, or a schedule
    /// whose window has opened (the server flips it to recording on its next
    /// tick). A schedule that hasn't started yet is not — it's cancelled from
    /// its programme, never stopped from the channel.
    static func isCapturing(_ recording: Recording, now: Date) -> Bool {
        switch recording.status {
        case .recording:
            true
        case .scheduled:
            recording.start <= now && now < recording.end
        default:
            false
        }
    }

    /// The recording capturing a channel right now, if any — what turns the
    /// channel's Record into Stop Recording. A later schedule of the same
    /// channel never does: Record still records what's on air.
    static func activeRecording(for sourceRef: RecordingSourceRef, now: Date, in recordings: [Recording]) -> Recording? {
        let raw = sourceRef.rawValue
        return recordings.first { $0.sourceRef == raw && isCapturing($0, now: now) }
    }

    /// The channel's pending recording of one guide programme. A recording
    /// planned from a programme ends `postRoll` after it, so its unpadded end
    /// identifies the programme, and the next programme's pre-roll never
    /// matches the one before it. On air (or in a live gap, `programme ==
    /// nil`) a recording capturing the channel right now also counts: Record
    /// would only start a second capture of the same feed.
    static func pendingRecording(
        for sourceRef: RecordingSourceRef,
        programme: Programme?,
        now: Date,
        in recordings: [Recording]
    ) -> Recording? {
        let raw = sourceRef.rawValue
        return recordings.first { recording in
            guard recording.status.isPending, recording.sourceRef == raw else { return false }
            if let programme {
                let unpaddedEnd = recording.end.addingTimeInterval(-postRoll)
                if unpaddedEnd > programme.start, unpaddedEnd <= programme.end { return true }
                guard timing(of: programme, now: now) == .live else { return false }
            }
            return isCapturing(recording, now: now)
        }
    }

    /// Drops recordings of channels in a category parental controls restrict
    /// for the active profile. `categoryID` maps a reference to its channel's
    /// category, or `nil` when the channel can't be found; recordings that
    /// can't be matched stay visible. Categories hidden in Content Management
    /// are a browsing preference and don't hide recordings.
    static func visibleRecordings(
        _ recordings: [Recording],
        restriction: ContentRestriction,
        categoryID: (RecordingSourceRef) -> String?
    ) -> [Recording] {
        guard restriction.isActive, !restriction.restrictedCategoryIDs.isEmpty else { return recordings }
        return recordings.filter { recording in
            guard let ref = recording.sourceRef.flatMap(RecordingSourceRef.init(rawValue:)),
                  let category = categoryID(ref)
            else { return true }
            return !restriction.restrictedCategoryIDs.contains(category)
        }
    }
}
