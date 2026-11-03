//
//  HueBridgeDiscoveryTests.swift
//  LumeTests
//
//  The bridge id Bonjour's TXT record carries, as discovery reads it.
//

@testable import Lume
import Testing

struct HueBridgeDiscoveryTests {
    @Test func `a TXT bridge id is lowercased`() {
        #expect(DiscoveredHueBridge.bridgeID(fromTXT: "001788FFFE6A1B2C") == "001788fffe6a1b2c")
    }

    @Test(arguments: [nil, "", "001788fffe6a1b", "001788fffe6a1b2c3d", "001788fffe6a1bzz"])
    func `a malformed TXT bridge id is ignored`(value: String?) {
        #expect(DiscoveredHueBridge.bridgeID(fromTXT: value) == nil)
    }
}
