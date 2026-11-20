//
//  VODSourceFailureHandoff.swift
//  Lume
//
//  Hands a grouped title's source that failed on every engine back to the
//  detail screen that opened it, so its source picker comes back with that
//  source marked failed. The player can't call the screen directly: on macOS
//  it lives in its own window, opened by value.
//

import Foundation
import Observation

@MainActor @Observable
final class VODSourceFailureHandoff {
    static let shared = VODSourceFailureHandoff()

    struct Failure: Equatable {
        let id = UUID()
        let mediaID: String
        /// The catalog row (`VODSourceOption.rowID`) the media came from: the
        /// movie itself, or the series an episode belongs to.
        let sourceRowID: String
    }

    /// The latest failure no detail screen has taken yet.
    private(set) var pending: Failure?

    @ObservationIgnored private var expected: [(mediaID: String, sourceRowID: String)] = []
    private static let capacity = 8

    /// Asks the player to hand a failure of `mediaID` back rather than show its
    /// own error, because the title has other sources to choose from.
    func expect(mediaID: String, sourceRowID: String) {
        expected.removeAll { $0.mediaID == mediaID }
        expected.append((mediaID, sourceRowID))
        if expected.count > Self.capacity {
            expected.removeFirst(expected.count - Self.capacity)
        }
    }

    func handsOff(mediaID: String) -> Bool {
        expected.contains { $0.mediaID == mediaID }
    }

    /// Records that `mediaID` failed on every engine. `false` when no screen
    /// asked for it, in which case the player keeps its own error overlay.
    func report(mediaID: String) -> Bool {
        guard let index = expected.firstIndex(where: { $0.mediaID == mediaID }) else { return false }
        let entry = expected.remove(at: index)
        pending = Failure(mediaID: mediaID, sourceRowID: entry.sourceRowID)
        return true
    }

    func release(mediaID: String) {
        expected.removeAll { $0.mediaID == mediaID }
    }

    /// Takes the pending failure when its source is one of `rowIDs`, the
    /// sources the asking screen offers.
    func take(ifAmong rowIDs: some Sequence<String>) -> Failure? {
        guard let pending, rowIDs.contains(pending.sourceRowID) else { return nil }
        self.pending = nil
        return pending
    }
}
