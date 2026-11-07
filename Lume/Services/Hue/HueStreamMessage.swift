//
//  HueStreamMessage.swift
//  Lume
//
//  One Hue Entertainment API v2 stream packet: the 52-byte header naming the
//  entertainment configuration, then 7 bytes per channel (id + 16-bit RGB).
//  The byte layout is the one verified against a real bridge, recorded in
//  `LumeTests/Fixtures/Hue/README.md`.
//

import Foundation

nonisolated struct HueStreamMessage: Hashable {
    nonisolated struct Channel: Hashable {
        var id: UInt8
        var red: UInt16
        var green: UInt16
        var blue: UInt16

        /// Components in `0...1`; out-of-range and NaN values are clamped.
        static func normalized(id: UInt8, red: Double, green: Double, blue: Double) -> Channel {
            Channel(id: id, red: component(red), green: component(green), blue: component(blue))
        }

        private static func component(_ value: Double) -> UInt16 {
            guard !value.isNaN else { return 0 }
            return UInt16((min(max(value, 0), 1) * Double(UInt16.max)).rounded())
        }
    }

    static let protocolName = Array("HueStream".utf8)
    static let headerLength = 52
    static let channelLength = 7
    /// The bridge accepts at most 20 channels per entertainment configuration.
    static let maximumChannelCount = 20

    let entertainmentConfigurationID: String
    var sequence: UInt8
    var channels: [Channel]

    /// Nil when the id isn't the 36-character ASCII UUID string the bridge
    /// expects, or when there are more channels than one packet may carry.
    init?(entertainmentConfigurationID: String, sequence: UInt8 = 0, channels: [Channel]) {
        let idBytes = entertainmentConfigurationID.utf8
        guard idBytes.count == 36, idBytes.allSatisfy({ $0 < 0x80 }),
              channels.count <= Self.maximumChannelCount
        else { return nil }
        self.entertainmentConfigurationID = entertainmentConfigurationID
        self.sequence = sequence
        self.channels = channels
    }

    func encoded() -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerLength + channels.count * Self.channelLength)
        bytes.append(contentsOf: Self.protocolName)
        bytes.append(contentsOf: [0x02, 0x00]) // API version 2.0
        bytes.append(sequence)
        bytes.append(contentsOf: [0x00, 0x00]) // reserved
        bytes.append(0x00) // colour space: RGB
        bytes.append(0x00) // reserved
        bytes.append(contentsOf: entertainmentConfigurationID.utf8)
        for channel in channels {
            bytes.append(channel.id)
            bytes.append(UInt8(channel.red >> 8))
            bytes.append(UInt8(channel.red & 0xFF))
            bytes.append(UInt8(channel.green >> 8))
            bytes.append(UInt8(channel.green & 0xFF))
            bytes.append(UInt8(channel.blue >> 8))
            bytes.append(UInt8(channel.blue & 0xFF))
        }
        return Data(bytes)
    }
}
