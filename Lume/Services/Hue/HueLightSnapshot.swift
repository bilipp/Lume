//
//  HueLightSnapshot.swift
//  Lume
//
//  What the area's lights showed before light sync took them over, and the
//  `PUT light/<id>` bodies that bring them back. Codable so a
//  snapshot outlives a crash mid-stream.
//

import Foundation

nonisolated struct HueLightSnapshot: Codable, Hashable {
    nonisolated enum Color: Codable, Hashable {
        case chromaticity(HueXY)
        case mirek(Int)
    }

    nonisolated struct LightState: Codable, Hashable {
        var lightID: String
        var isOn: Bool
        /// Percent; nil for lights without dimming.
        var brightness: Double?
        /// Nil for lights without colour or colour temperature.
        var color: Color?
    }

    nonisolated struct Restore: Hashable {
        var lightID: String
        var update: HueLightUpdate
    }

    var lights: [LightState]

    init(lights: [LightState]) {
        self.lights = lights
    }

    /// Captures `lights`, limited to `lightIDs` when given, sorted by id.
    init(capturing lights: [HueLight], lightIDs: Set<String>? = nil) {
        self.lights = lights
            .filter { lightIDs?.contains($0.id) ?? true }
            .sorted { $0.id < $1.id }
            .map(LightState.init(light:))
    }

    /// The whole captured state of every light, one `PUT light/<id>` body
    /// each. Never diffed against the bridge: streamed colours never reach
    /// the CLIP light resources, which still report the pre-stream state.
    var restoreUpdates: [Restore] {
        lights.map { Restore(lightID: $0.lightID, update: $0.update) }
    }
}

nonisolated extension HueLightSnapshot.LightState {
    init(light: HueLight) {
        let color: HueLightSnapshot.Color? = if let mirek = light.activeMirek {
            .mirek(mirek)
        } else if let point = light.color?.chromaticity {
            .chromaticity(point)
        } else {
            nil
        }
        self.init(lightID: light.id, isOn: light.isOn, brightness: light.dimming?.brightness, color: color)
    }

    var update: HueLightUpdate {
        var update = HueLightUpdate(power: HueOnState(on: isOn))
        if let brightness {
            update.dimming = .init(brightness: brightness)
        }
        switch color {
        case let .mirek(mirek):
            update.colorTemperature = .init(mirek: mirek)
        case let .chromaticity(point):
            update.color = .init(xy: point)
        case nil:
            break
        }
        return update
    }
}
