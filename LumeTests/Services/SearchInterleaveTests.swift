//
//  SearchInterleaveTests.swift
//  LumeTests
//
//  Covers `interleaved(_:limit:)`, the rotation search spends its budget with
//  when hits arrive from several Stalker portals — each ranks its own results,
//  so concatenating would bury the second portal's best match.
//

import Foundation
@testable import Lume
import Testing

struct SearchInterleaveTests {
    @Test func `one list passes through, bounded by the limit`() {
        #expect(interleaved([["a", "b", "c"]], limit: 2) == ["a", "b"])
    }

    @Test func `no lists yield nothing`() {
        #expect(interleaved([[String]](), limit: 5).isEmpty)
    }

    @Test func `lists alternate so every portal places its best hit`() {
        let merged = interleaved([["a1", "a2", "a3"], ["b1", "b2", "b3"]], limit: 4)
        #expect(merged == ["a1", "b1", "a2", "b2"])
    }

    @Test func `a short list hands its remaining share back`() {
        let merged = interleaved([["a1", "a2", "a3", "a4"], ["b1"]], limit: 4)
        #expect(merged == ["a1", "b1", "a2", "a3"])
    }

    @Test func `an element two portals both return is listed once`() {
        let merged = interleaved([["shared", "a2"], ["shared", "b2"]], limit: 4)
        #expect(merged == ["shared", "a2", "b2"])
    }

    @Test func `the walk ends when every list is spent`() {
        #expect(interleaved([["a1"], ["b1"]], limit: 50) == ["a1", "b1"])
    }
}
