//
//  RemoteDirectionGateTests.swift
//  LumeTests
//
//  Pins the pairing that lets the tvOS player act on the remote's direction
//  buttons while ignoring swipes. Neither `MoveCommandDirection` nor `UIPress`
//  exists on iOS, where these tests run, which is exactly why the gate models
//  directions itself.
//

import Foundation
@testable import Lume
import Testing

@Suite("RemoteDirectionGate")
struct RemoteDirectionGateTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func `a swipe alone never acts`() {
        var gate = RemoteDirectionGate()
        #expect(gate.noteMove(.up, at: start) == false)
    }

    @Test
    func `a click acts once when the press lands first`() {
        var gate = RemoteDirectionGate()
        #expect(gate.notePress(.up, at: start) == false)
        #expect(gate.noteMove(.up, at: start.addingTimeInterval(0.001)) == true)
    }

    @Test
    func `a click acts once when the move lands first`() {
        var gate = RemoteDirectionGate()
        #expect(gate.noteMove(.down, at: start) == false)
        #expect(gate.notePress(.down, at: start.addingTimeInterval(0.001)) == true)
    }

    @Test
    func `one press cannot confirm two moves`() {
        var gate = RemoteDirectionGate()
        _ = gate.notePress(.left, at: start)
        #expect(gate.noteMove(.left, at: start.addingTimeInterval(0.01)) == true)
        #expect(gate.noteMove(.left, at: start.addingTimeInterval(0.02)) == false)
    }

    @Test
    func `one move cannot be confirmed twice`() {
        var gate = RemoteDirectionGate()
        _ = gate.noteMove(.right, at: start)
        #expect(gate.notePress(.right, at: start.addingTimeInterval(0.01)) == true)
        #expect(gate.notePress(.right, at: start.addingTimeInterval(0.02)) == false)
    }

    @Test
    func `a press in another direction confirms nothing`() {
        var gate = RemoteDirectionGate()
        _ = gate.noteMove(.up, at: start)
        #expect(gate.notePress(.down, at: start.addingTimeInterval(0.01)) == false)
    }

    @Test
    func `a stale press confirms nothing`() {
        var gate = RemoteDirectionGate()
        _ = gate.notePress(.up, at: start)
        let late = start.addingTimeInterval(RemoteDirectionGate.pairingWindow + 0.01)
        #expect(gate.noteMove(.up, at: late) == false)
    }

    @Test
    func `a stale move is not confirmed by a later press`() {
        var gate = RemoteDirectionGate()
        _ = gate.noteMove(.up, at: start)
        let late = start.addingTimeInterval(RemoteDirectionGate.pairingWindow + 0.01)
        #expect(gate.notePress(.up, at: late) == false)
    }

    @Test
    func `a mismatched press clears the parked move`() {
        var gate = RemoteDirectionGate()
        _ = gate.noteMove(.up, at: start)
        _ = gate.notePress(.down, at: start.addingTimeInterval(0.01))
        // The up move is gone: the down press must not confirm it late.
        #expect(gate.notePress(.up, at: start.addingTimeInterval(0.02)) == false)
    }

    @Test
    func `swipes stay on by default`() {
        #expect(PlayerSettings.tvRemoteSwipesDefault == true)
    }
}
