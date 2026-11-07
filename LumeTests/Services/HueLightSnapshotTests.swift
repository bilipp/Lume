//
//  HueLightSnapshotTests.swift
//  LumeTests
//
//  Capturing the area's lights before streaming and putting them back.
//

import Foundation
@testable import Lume
import Testing

struct HueLightSnapshotTests {
    private static let strip = "light-a"
    private static let bulb = "light-b"
    private static let outsideArea = "light-z"

    private static func colourLight(
        _ id: String,
        isOn: Bool = true,
        brightness: Double = 50,
        chromaticity: HueXY = HueXY(x: 0.3, y: 0.3),
        mirek: Int? = nil
    ) -> HueLight {
        HueLight(
            id: id,
            isOn: isOn,
            dimming: .init(brightness: brightness),
            color: .init(chromaticity: chromaticity),
            colorTemperature: .init(mirek: mirek, mirekValid: mirek != nil)
        )
    }

    @Test func `capture keeps only the area's lights, sorted`() {
        let snapshot = HueLightSnapshot(
            capturing: [Self.colourLight(Self.bulb), Self.colourLight(Self.outsideArea), Self.colourLight(Self.strip)],
            lightIDs: [Self.strip, Self.bulb]
        )
        #expect(snapshot.lights.map(\.lightID) == [Self.strip, Self.bulb])
    }

    @Test func `capture records ct mode as mirek and xy mode as xy`() {
        let snapshot = HueLightSnapshot(capturing: [
            Self.colourLight(Self.strip, chromaticity: HueXY(x: 0.6, y: 0.3)),
            Self.colourLight(Self.bulb, brightness: 80, chromaticity: HueXY(x: 0.45, y: 0.4), mirek: 370)
        ])
        #expect(snapshot.lights == [
            .init(lightID: Self.strip, isOn: true, brightness: 50, color: .chromaticity(HueXY(x: 0.6, y: 0.3))),
            .init(lightID: Self.bulb, isOn: true, brightness: 80, color: .mirek(370))
        ])
    }

    @Test func `a plain on-off light captures no brightness or colour`() {
        let snapshot = HueLightSnapshot(capturing: [HueLight(id: Self.strip, isOn: false)])
        #expect(snapshot.lights == [.init(lightID: Self.strip, isOn: false, brightness: nil, color: nil)])
    }

    @Test func `restore sends every light's whole state, whatever the bridge reports`() {
        let snapshot = HueLightSnapshot(capturing: [
            Self.colourLight(Self.strip, brightness: 40, chromaticity: HueXY(x: 0.6, y: 0.3)),
            Self.colourLight(Self.bulb, brightness: 80, mirek: 370)
        ])

        #expect(snapshot.restoreUpdates == [
            .init(lightID: Self.strip, update: HueLightUpdate(
                power: HueOnState(on: true),
                dimming: .init(brightness: 40),
                color: .init(xy: HueXY(x: 0.6, y: 0.3))
            )),
            .init(lightID: Self.bulb, update: HueLightUpdate(
                power: HueOnState(on: true),
                dimming: .init(brightness: 80),
                colorTemperature: .init(mirek: 370)
            ))
        ])
    }

    @Test func `a light that was off is switched off again`() {
        let snapshot = HueLightSnapshot(capturing: [Self.colourLight(Self.strip, isOn: false, brightness: 30)])

        #expect(snapshot.restoreUpdates == [
            .init(lightID: Self.strip, update: HueLightUpdate(
                power: HueOnState(on: false),
                dimming: .init(brightness: 30),
                color: .init(xy: HueXY(x: 0.3, y: 0.3))
            ))
        ])
    }

    @Test func `a plain on-off light restores only its power`() {
        let snapshot = HueLightSnapshot(capturing: [HueLight(id: Self.strip, isOn: true)])
        #expect(snapshot.restoreUpdates == [.init(lightID: Self.strip, update: HueLightUpdate(power: HueOnState(on: true)))])
    }

    @Test func `a snapshot survives a JSON round trip`() throws {
        let snapshot = HueLightSnapshot(capturing: [
            Self.colourLight(Self.strip, chromaticity: HueXY(x: 0.6, y: 0.3)),
            Self.colourLight(Self.bulb, isOn: false, mirek: 370),
            HueLight(id: Self.outsideArea, isOn: true)
        ])
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(HueLightSnapshot.self, from: data) == snapshot)
    }

    @Test func `restore bodies encode as CLIP v2 JSON`() throws {
        let snapshot = HueLightSnapshot(capturing: [Self.colourLight(Self.bulb, brightness: 80, mirek: 370)])
        let restore = try #require(snapshot.restoreUpdates.first)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(restore.update)
        #expect(String(bytes: json, encoding: .utf8) == #"{"color_temperature":{"mirek":370},"dimming":{"brightness":80},"on":{"on":true}}"#)
    }
}
