//
//  HueCLIPModels.swift
//  Lume
//
//  CLIP v2 (`/clip/v2/resource/…`) DTOs for the parts of the bridge API light
//  sync uses. Only the fields Lume reads are modelled; everything the bridge
//  may omit is optional, and enum-like values stay strings so a new firmware
//  value never fails a whole response.
//

import Foundation

/// The `{ "errors": [...], "data": [...] }` envelope every CLIP v2 call returns.
nonisolated struct HueResponse<Resource: Decodable>: Decodable {
    var errors: [HueAPIError]
    var data: [Resource]

    private enum CodingKeys: String, CodingKey {
        case errors, data
    }

    init(errors: [HueAPIError] = [], data: [Resource] = []) {
        self.errors = errors
        self.data = data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = try container.decodeIfPresent([HueAPIError].self, forKey: .errors) ?? []
        data = try container.decodeIfPresent([Resource].self, forKey: .data) ?? []
    }
}

nonisolated struct HueAPIError: Codable, Hashable {
    var description: String
}

/// A `{ "rid": …, "rtype": … }` reference to another resource.
nonisolated struct HueResourceReference: Codable, Hashable {
    var rid: String
    var rtype: String
}

nonisolated struct HueResourceMetadata: Codable, Hashable {
    var name: String
}

// MARK: - Entertainment configuration

// swiftlint:disable identifier_name - the bridge's axis keys.
/// A point in an entertainment configuration's space; every axis runs
/// `-1...1` (x left→right, y back→front, z bottom→top).
nonisolated struct HuePosition: Codable, Hashable {
    var x: Double
    var y: Double
    var z: Double
}

// swiftlint:enable identifier_name

nonisolated struct HueEntertainmentChannel: Decodable, Hashable {
    nonisolated struct Member: Decodable, Hashable {
        /// An `entertainment` service; its `renderer_reference` is the light.
        var service: HueResourceReference
        var index: Int
    }

    var channelID: Int
    var position: HuePosition
    var members: [Member]

    private enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case position, members
    }

    init(channelID: Int, position: HuePosition, members: [Member]) {
        self.channelID = channelID
        self.position = position
        self.members = members
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try container.decode(Int.self, forKey: .channelID)
        position = try container.decode(HuePosition.self, forKey: .position)
        members = try container.decodeIfPresent([Member].self, forKey: .members) ?? []
    }
}

nonisolated struct HueServiceLocation: Decodable, Hashable {
    var service: HueResourceReference
    var positions: [HuePosition]
}

nonisolated struct HueEntertainmentConfiguration: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    /// `screen`, `monitor`, `music`, `3dspace` or `other`.
    var configurationType: String
    /// `active` while some client streams to the area, else `inactive`.
    var status: String
    /// The application streaming to the area; present only while active.
    var activeStreamer: HueResourceReference?
    var channels: [HueEntertainmentChannel]
    var serviceLocations: [HueServiceLocation]
    var lightServices: [HueResourceReference]

    var isStreaming: Bool {
        status == "active"
    }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, status, channels, locations
        case configurationType = "configuration_type"
        case activeStreamer = "active_streamer"
        case lightServices = "light_services"
    }

    private enum LocationKeys: String, CodingKey {
        case serviceLocations = "service_locations"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(HueResourceMetadata.self, forKey: .metadata).name
        configurationType = try container.decodeIfPresent(String.self, forKey: .configurationType) ?? "other"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "inactive"
        activeStreamer = try container.decodeIfPresent(HueResourceReference.self, forKey: .activeStreamer)
        channels = try container.decodeIfPresent([HueEntertainmentChannel].self, forKey: .channels) ?? []
        if container.contains(.locations), try !container.decodeNil(forKey: .locations) {
            let locations = try container.nestedContainer(keyedBy: LocationKeys.self, forKey: .locations)
            serviceLocations = try locations.decodeIfPresent([HueServiceLocation].self, forKey: .serviceLocations) ?? []
        } else {
            serviceLocations = []
        }
        lightServices = try container.decodeIfPresent([HueResourceReference].self, forKey: .lightServices) ?? []
    }

    /// The light ids of the area: the configuration's own `light_services`,
    /// plus the lights behind its channel members and service locations.
    func lightIDs(entertainmentServices: [HueEntertainmentService] = []) -> Set<String> {
        var ids = Set(lightServices.filter { $0.rtype == "light" }.map(\.rid))
        let renderers = Dictionary(
            entertainmentServices.compactMap { service in
                service.rendererReference.map { (service.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let memberServices = channels.flatMap(\.members).map(\.service)
            + serviceLocations.map(\.service)
        for service in memberServices {
            if service.rtype == "light" {
                ids.insert(service.rid)
            } else if let renderer = renderers[service.rid], renderer.rtype == "light" {
                ids.insert(renderer.rid)
            }
        }
        return ids
    }
}

/// The `entertainment` service of a device: what entertainment channels
/// reference, and the light it renders on.
nonisolated struct HueEntertainmentService: Decodable, Hashable, Identifiable {
    var id: String
    var renderer: Bool
    var rendererReference: HueResourceReference?

    private enum CodingKeys: String, CodingKey {
        case id, renderer
        case rendererReference = "renderer_reference"
    }

    init(id: String, renderer: Bool, rendererReference: HueResourceReference?) {
        self.id = id
        self.renderer = renderer
        self.rendererReference = rendererReference
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        renderer = try container.decodeIfPresent(Bool.self, forKey: .renderer) ?? false
        rendererReference = try container.decodeIfPresent(HueResourceReference.self, forKey: .rendererReference)
    }
}

/// Body of `PUT entertainment_configuration/<id>` that opens or closes streaming.
nonisolated struct HueEntertainmentAction: Encodable, Hashable {
    var action: String

    static let start = HueEntertainmentAction(action: "start")
    static let stop = HueEntertainmentAction(action: "stop")
}

// MARK: - Light

// swiftlint:disable identifier_name - the bridge's axis keys.
/// A CIE 1931 chromaticity coordinate.
nonisolated struct HueXY: Codable, Hashable {
    var x: Double
    var y: Double
}

// swiftlint:enable identifier_name

/// CLIP v2's `{ "on": Bool }` object.
nonisolated struct HueOnState: Codable, Hashable {
    // swiftlint:disable:next identifier_name - the bridge's key.
    var on: Bool
}

nonisolated struct HueGamut: Codable, Hashable {
    var red: HueXY
    var green: HueXY
    var blue: HueXY
}

nonisolated struct HueLightColor: Decodable, Hashable {
    var chromaticity: HueXY
    var gamut: HueGamut?
    /// `A`, `B`, `C` or `other`.
    var gamutType: String?

    private enum CodingKeys: String, CodingKey {
        case gamut
        case chromaticity = "xy"
        case gamutType = "gamut_type"
    }

    init(chromaticity: HueXY, gamut: HueGamut? = nil, gamutType: String? = nil) {
        self.chromaticity = chromaticity
        self.gamut = gamut
        self.gamutType = gamutType
    }
}

nonisolated struct HueColorTemperature: Decodable, Hashable {
    /// Nil while the light shows an xy colour.
    var mirek: Int?
    /// False while the light shows an xy colour.
    var mirekValid: Bool

    private enum CodingKeys: String, CodingKey {
        case mirek
        case mirekValid = "mirek_valid"
    }

    init(mirek: Int?, mirekValid: Bool) {
        self.mirek = mirek
        self.mirekValid = mirekValid
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mirek = try container.decodeIfPresent(Int.self, forKey: .mirek)
        mirekValid = try container.decodeIfPresent(Bool.self, forKey: .mirekValid) ?? (mirek != nil)
    }
}

nonisolated struct HueLight: Decodable, Hashable, Identifiable {
    nonisolated struct Dimming: Codable, Hashable {
        /// Percent, `0...100`.
        var brightness: Double
    }

    var id: String
    var name: String?
    var isOn: Bool
    var dimming: Dimming?
    var color: HueLightColor?
    var colorTemperature: HueColorTemperature?
    /// `normal`, or `streaming` while an entertainment stream drives it.
    var mode: String?

    /// The colour temperature, when that — not an xy colour — is what shows.
    var activeMirek: Int? {
        guard let colorTemperature, colorTemperature.mirekValid else { return nil }
        return colorTemperature.mirek
    }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, dimming, color, mode
        case power = "on"
        case colorTemperature = "color_temperature"
    }

    init(
        id: String,
        name: String? = nil,
        isOn: Bool,
        dimming: Dimming? = nil,
        color: HueLightColor? = nil,
        colorTemperature: HueColorTemperature? = nil,
        mode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isOn = isOn
        self.dimming = dimming
        self.color = color
        self.colorTemperature = colorTemperature
        self.mode = mode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(HueResourceMetadata.self, forKey: .metadata)?.name
        isOn = try container.decode(HueOnState.self, forKey: .power).on
        dimming = try container.decodeIfPresent(Dimming.self, forKey: .dimming)
        color = try container.decodeIfPresent(HueLightColor.self, forKey: .color)
        colorTemperature = try container.decodeIfPresent(HueColorTemperature.self, forKey: .colorTemperature)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
    }
}

/// Body of `PUT light/<id>`. Nil fields are left out of the JSON, so the
/// bridge changes only what is set.
nonisolated struct HueLightUpdate: Codable, Hashable {
    nonisolated struct Color: Codable, Hashable {
        // swiftlint:disable:next identifier_name - the bridge's key.
        var xy: HueXY
    }

    nonisolated struct ColorTemperature: Codable, Hashable {
        var mirek: Int
    }

    var power: HueOnState?
    var dimming: HueLight.Dimming?
    var color: Color?
    var colorTemperature: ColorTemperature?

    private enum CodingKeys: String, CodingKey {
        case dimming, color
        case power = "on"
        case colorTemperature = "color_temperature"
    }

    init(
        power: HueOnState? = nil,
        dimming: HueLight.Dimming? = nil,
        color: Color? = nil,
        colorTemperature: ColorTemperature? = nil
    ) {
        self.power = power
        self.dimming = dimming
        self.color = color
        self.colorTemperature = colorTemperature
    }
}
