//
//  RemoteDirectionGate.swift
//  Lume
//
//  Decides whether a directional move the tvOS player received came from a
//  click on the Siri Remote's direction buttons rather than a swipe across its
//  touch surface. Kept here as pure, cross-platform logic — no UIKit, no view
//  state — because neither `MoveCommandDirection` nor `UIPress` exists on iOS
//  and the test target only runs on iOS simulators.
//
//  The problem it solves: tvOS reports swipes and clicks through the same
//  `onMoveCommand`, so a handler alone cannot tell them apart. A click *also*
//  emits a `UIPress` of an arrow type, which a swipe never does — see
//  `TVRemoteDirectionInput` for the observer that reports those presses. What
//  is left is pairing the two, and the two arrive in the same press cycle with
//  no guaranteed order: the focus engine's recognizers and ours both run off
//  the same event, and which fires first is UIKit's business.
//
//  So the gate accepts either order. Each side records what it saw and looks
//  for its unpaired counterpart; whichever arrives second fires the action, and
//  the pairing is consumed so one click can only ever act once. A swipe records
//  a move that pairs with nothing and expires.
//

import Foundation

/// Pairs directional moves with the button presses that caused them, so the
/// player can act on clicks alone while swipes are turned off.
///
/// Not a general input router: it holds one move and one press at a time, which
/// is all a remote can produce inside the pairing window.
nonisolated struct RemoteDirectionGate {
    /// A direction on the remote, mirroring the four `MoveCommandDirection`
    /// cases the tvOS callers translate from.
    enum Direction: Hashable {
        // `up` is two characters: the cases are named for the keys.
        // swiftlint:disable identifier_name
        case up
        case down
        // swiftlint:enable identifier_name
        case left
        case right
    }

    /// How long a move and a press may sit apart and still count as the same
    /// input. Generous next to the few milliseconds that actually separate the
    /// two recognizers, and far short of how fast a viewer can swipe and then
    /// click the same direction deliberately.
    static let pairingWindow: TimeInterval = 0.3

    private var pendingMove: (direction: Direction, at: Date)?
    private var pendingPress: (direction: Direction, at: Date)?

    init() {}

    /// Records a directional move and reports whether it can be attributed to a
    /// button press — a click whose press half already arrived, or one still to
    /// come, in which case `notePress` fires instead.
    mutating func noteMove(_ direction: Direction, at now: Date = Date()) -> Bool {
        if Self.take(&pendingPress, matching: direction, at: now) {
            return true
        }
        pendingMove = (direction, now)
        return false
    }

    /// Records a directional button press and reports whether it completes a
    /// move already delivered. `false` only means the move half hasn't arrived
    /// yet; `noteMove` fires when it does.
    mutating func notePress(_ direction: Direction, at now: Date = Date()) -> Bool {
        if Self.take(&pendingMove, matching: direction, at: now) {
            return true
        }
        pendingPress = (direction, now)
        return false
    }

    /// Consumes `half` when it holds an unexpired counterpart in the same
    /// direction. Consuming either way is what keeps one click to one action:
    /// the second half of a pair finds nothing left to match.
    private static func take(
        _ half: inout (direction: Direction, at: Date)?,
        matching direction: Direction,
        at now: Date
    ) -> Bool {
        guard let pending = half else { return false }
        // Expired or pointing elsewhere: drop it either way, it can only go
        // stale from here.
        half = nil
        guard pending.direction == direction,
              now.timeIntervalSince(pending.at) < Self.pairingWindow else { return false }
        return true
    }
}
