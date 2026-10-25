//
//  RecordingProgressStore.swift
//  Lume
//
//  Where a recording was left off, per device. Recordings are not catalog
//  rows, so their resume point lives in UserDefaults under
//  `recordingProgress.<identifier>` — written once when a playback session
//  ends, read when the next one starts. A LumeRecorder identifier is the bare
//  recording UUID (the keys earlier builds wrote); a Dispatcharr id is a small
//  integer only unique per server, so it is prefixed with its server's
//  namespace (`dispatcharr-<serverID>-<id>`).
//

import Foundation

nonisolated enum RecordingProgressStore {
    static let keyPrefix = "recordingProgress."

    /// Past this share of the duration the recording counts as finished and
    /// the next playback starts over.
    static let finishedFraction = 0.95

    static func key(for recordingID: String) -> String {
        keyPrefix + recordingID.lowercased()
    }

    static let dispatcharrNamespacePrefix = "dispatcharr-"

    /// The namespace a server's recording ids are keyed under; `nil` for a
    /// LumeRecorder server, whose ids are globally unique UUIDs.
    static func namespace(kind: RecordingServerKind, serverID: UUID) -> String? {
        switch kind {
        case .lumeRecorder: nil
        case .dispatcharr: dispatcharrNamespacePrefix + serverID.uuidString.lowercased()
        }
    }

    static func identifier(for recordingID: RecordingID, namespace: String? = nil) -> String {
        guard let namespace else { return recordingID.rawValue.lowercased() }
        return "\(namespace)-\(recordingID.rawValue)".lowercased()
    }

    /// Whether `identifier` names a recording on a Dispatcharr server.
    static func isDispatcharr(_ identifier: String) -> Bool {
        identifier.hasPrefix(dispatcharrNamespacePrefix)
    }

    /// The stored position for `recordingID`, or 0 when there is none.
    static func position(for recordingID: String, defaults: UserDefaults = .standard) -> TimeInterval {
        max(0, defaults.double(forKey: key(for: recordingID)))
    }

    /// Where playback of `recording` should open. A recording still being
    /// written opens at its start, since its duration keeps growing.
    static func resumePosition(
        for recording: ServerRecording,
        namespace: String? = nil,
        defaults: UserDefaults = .standard
    ) -> TimeInterval {
        guard !recording.status.isPending else { return 0 }
        return position(for: identifier(for: recording.id, namespace: namespace), defaults: defaults)
    }

    /// Stores `progress` at the end of a session. A non-positive position is
    /// ignored so a flush after the clock reset cannot erase the real one; a
    /// position at the end clears the entry.
    static func save(
        recordingID: String,
        progress: TimeInterval,
        duration: TimeInterval,
        defaults: UserDefaults = .standard
    ) {
        guard progress > 1 else { return }
        if duration > 0, progress / duration >= finishedFraction {
            defaults.removeObject(forKey: key(for: recordingID))
        } else {
            defaults.set(progress, forKey: key(for: recordingID))
        }
    }

    static func remove(recordingID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: recordingID))
    }
}
