//
//  HueStreamMessageTests.swift
//  LumeTests
//
//  Golden bytes for the Hue Entertainment API v2 stream packet.
//

import Foundation
@testable import Lume
import Testing

struct HueStreamMessageTests {
    private static let areaID = "8d199a37-5ce4-4aae-a60e-db5d0aa27df3"

    private static let header: [UInt8] = [
        0x48, 0x75, 0x65, 0x53, 0x74, 0x72, 0x65, 0x61, 0x6D, // "HueStream"
        0x02, 0x00 // version 2.0
    ]

    @Test func `two channels encode to the verified layout`() throws {
        let message = try #require(HueStreamMessage(
            entertainmentConfigurationID: Self.areaID,
            sequence: 7,
            channels: [
                .init(id: 0, red: 0xFFFF, green: 0x0000, blue: 0x1234),
                .init(id: 1, red: 0x00FF, green: 0xFF00, blue: 0x8000)
            ]
        ))

        let expected: [UInt8] = Self.header
            + [0x07, 0x00, 0x00, 0x00, 0x00]
            + Array(Self.areaID.utf8)
            + [0x00, 0xFF, 0xFF, 0x00, 0x00, 0x12, 0x34]
            + [0x01, 0x00, 0xFF, 0xFF, 0x00, 0x80, 0x00]

        let bytes = Array(message.encoded())
        #expect(bytes == expected)
        #expect(bytes.count == HueStreamMessage.headerLength + 2 * HueStreamMessage.channelLength)
    }

    @Test func `no channels is the bare header`() throws {
        let message = try #require(HueStreamMessage(entertainmentConfigurationID: Self.areaID, channels: []))
        let bytes = Array(message.encoded())
        #expect(bytes.count == 52)
        #expect(Array(bytes[0 ..< 11]) == Self.header)
        #expect(Array(bytes[16...]) == Array(Self.areaID.utf8))
    }

    @Test func `sequence lands in byte 11`() throws {
        var message = try #require(HueStreamMessage(entertainmentConfigurationID: Self.areaID, channels: []))
        message.sequence = 0xFE
        #expect(message.encoded()[11] == 0xFE)
    }

    @Test(arguments: [
        (1.0, UInt16.max),
        (0.0, UInt16(0)),
        (0.5, UInt16(32768)),
        (1.7, UInt16.max),
        (-0.2, UInt16(0)),
        (Double.nan, UInt16(0))
    ])
    func `unit components scale and clamp to 16 bits`(input: Double, expected: UInt16) {
        let channel = HueStreamMessage.Channel.normalized(id: 3, red: input, green: input, blue: input)
        #expect(channel.red == expected)
        #expect(channel.green == expected)
        #expect(channel.blue == expected)
    }

    @Test(arguments: ["", "8d199a37", "8d199a37-5ce4-4aae-a60e-db5d0aa27df3x", "8d199a37-5ce4-4aae-a60e-db5d0aa27dé"])
    func `an id that isn't a 36-character ASCII UUID is rejected`(id: String) {
        #expect(HueStreamMessage(entertainmentConfigurationID: id, channels: []) == nil)
    }

    @Test func `more than twenty channels is rejected`() {
        let channels = (0 ... 20).map { HueStreamMessage.Channel(id: UInt8($0), red: 0, green: 0, blue: 0) }
        #expect(HueStreamMessage(entertainmentConfigurationID: Self.areaID, channels: channels) == nil)
        #expect(HueStreamMessage(entertainmentConfigurationID: Self.areaID, channels: Array(channels.prefix(20))) != nil)
    }
}
