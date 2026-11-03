//
//  HueCLIPModelsTests.swift
//  LumeTests
//
//  CLIP v2 DTO decoding from inline JSON shaped like the bridge's answers,
//  including the real 'TV' entertainment area (ids of members are invented).
//

import Foundation
@testable import Lume
import Testing

struct HueCLIPModelsTests {
    static let tvAreaJSON = """
    {
      "errors": [],
      "data": [
        {
          "id": "8d199a37-5ce4-4aae-a60e-db5d0aa27df3",
          "id_v1": "/groups/200",
          "type": "entertainment_configuration",
          "metadata": { "name": "TV" },
          "name": "TV",
          "configuration_type": "screen",
          "status": "inactive",
          "stream_proxy": {
            "mode": "auto",
            "node": { "rid": "0e6b1c4e-0000-4000-8000-000000000001", "rtype": "entertainment" }
          },
          "channels": [
            {
              "channel_id": 0,
              "position": { "x": 0.47, "y": 1.0, "z": -1.0 },
              "members": [
                { "service": { "rid": "0e6b1c4e-0000-4000-8000-000000000001", "rtype": "entertainment" }, "index": 0 }
              ]
            },
            {
              "channel_id": 1,
              "position": { "x": -0.11, "y": 0.04, "z": 1.0 },
              "members": [
                { "service": { "rid": "0e6b1c4e-0000-4000-8000-000000000002", "rtype": "entertainment" }, "index": 0 }
              ]
            }
          ],
          "locations": {
            "service_locations": [
              {
                "service": { "rid": "0e6b1c4e-0000-4000-8000-000000000001", "rtype": "entertainment" },
                "position": { "x": 0.47, "y": 1.0, "z": -1.0 },
                "positions": [{ "x": 0.47, "y": 1.0, "z": -1.0 }],
                "equalization_factor": 1.0
              },
              {
                "service": { "rid": "0e6b1c4e-0000-4000-8000-000000000002", "rtype": "entertainment" },
                "position": { "x": -0.11, "y": 0.04, "z": 1.0 },
                "positions": [{ "x": -0.11, "y": 0.04, "z": 1.0 }],
                "equalization_factor": 1.0
              }
            ]
          },
          "light_services": [
            { "rid": "1a2b3c4d-0000-4000-8000-00000000000a", "rtype": "light" },
            { "rid": "1a2b3c4d-0000-4000-8000-00000000000b", "rtype": "light" }
          ]
        }
      ]
    }
    """

    @Test func `the real TV area decodes`() throws {
        let response = try JSONDecoder().decode(
            HueResponse<HueEntertainmentConfiguration>.self,
            from: Data(Self.tvAreaJSON.utf8)
        )
        #expect(response.errors.isEmpty)
        let area = try #require(response.data.first)
        #expect(area.id == "8d199a37-5ce4-4aae-a60e-db5d0aa27df3")
        #expect(area.name == "TV")
        #expect(area.configurationType == "screen")
        #expect(!area.isStreaming)
        #expect(area.activeStreamer == nil)
        #expect(area.channels.map(\.channelID) == [0, 1])
        #expect(area.channels[0].position == .init(x: 0.47, y: 1.0, z: -1.0))
        #expect(area.channels[1].position == .init(x: -0.11, y: 0.04, z: 1.0))
        #expect(area.channels[1].members.first?.service.rtype == "entertainment")
        #expect(area.serviceLocations.count == 2)
        #expect(area.lightIDs() == [
            "1a2b3c4d-0000-4000-8000-00000000000a",
            "1a2b3c4d-0000-4000-8000-00000000000b"
        ])
    }

    @Test func `an area streamed by someone else reports its streamer`() throws {
        let json = """
        {
          "data": [{
            "id": "11111111-2222-4333-8444-555555555555",
            "metadata": { "name": "Bildschirm" },
            "configuration_type": "monitor",
            "status": "active",
            "active_streamer": { "rid": "99999999-0000-4000-8000-000000000000", "rtype": "auth_v1" },
            "channels": [{ "channel_id": 0, "position": { "x": 0, "y": 0.8, "z": 0 }, "members": [] }]
          }]
        }
        """
        let response = try JSONDecoder().decode(HueResponse<HueEntertainmentConfiguration>.self, from: Data(json.utf8))
        #expect(response.errors.isEmpty)
        let area = try #require(response.data.first)
        #expect(area.isStreaming)
        #expect(area.activeStreamer?.rtype == "auth_v1")
        #expect(area.configurationType == "monitor")
        #expect(area.lightServices.isEmpty)
        #expect(area.serviceLocations.isEmpty)
    }

    @Test func `area lights resolve through entertainment services`() throws {
        let json = """
        {
          "errors": [],
          "data": [
            {
              "id": "0e6b1c4e-0000-4000-8000-000000000001",
              "type": "entertainment",
              "renderer": true,
              "renderer_reference": { "rid": "1a2b3c4d-0000-4000-8000-0000000000aa", "rtype": "light" },
              "proxy": true,
              "max_streams": 1
            },
            {
              "id": "0e6b1c4e-0000-4000-8000-000000000002",
              "type": "entertainment",
              "renderer": true,
              "renderer_reference": { "rid": "1a2b3c4d-0000-4000-8000-0000000000bb", "rtype": "light" }
            },
            { "id": "0e6b1c4e-0000-4000-8000-000000000003", "type": "entertainment", "renderer": false }
          ]
        }
        """
        let services = try JSONDecoder().decode(HueResponse<HueEntertainmentService>.self, from: Data(json.utf8)).data
        #expect(services.count == 3)
        #expect(services[2].rendererReference == nil)

        var area = try #require(try JSONDecoder().decode(
            HueResponse<HueEntertainmentConfiguration>.self,
            from: Data(Self.tvAreaJSON.utf8)
        ).data.first)
        area.lightServices = []
        #expect(area.lightIDs().isEmpty)
        #expect(area.lightIDs(entertainmentServices: services) == [
            "1a2b3c4d-0000-4000-8000-0000000000aa",
            "1a2b3c4d-0000-4000-8000-0000000000bb"
        ])
    }

    @Test func `errors decode next to empty data`() throws {
        let json = #"{ "errors": [{ "description": "Not Found" }], "data": [] }"#
        let response = try JSONDecoder().decode(HueResponse<HueLight>.self, from: Data(json.utf8))
        #expect(response.errors == [HueAPIError(description: "Not Found")])
        #expect(response.data.isEmpty)
    }

    @Test func `a colour light in xy mode decodes`() throws {
        let json = """
        {
          "errors": [],
          "data": [{
            "id": "1a2b3c4d-0000-4000-8000-0000000000aa",
            "type": "light",
            "metadata": { "name": "Lightstrip", "archetype": "hue_lightstrip_tv" },
            "on": { "on": true },
            "dimming": { "brightness": 62.45, "min_dim_level": 0.2 },
            "color_temperature": {
              "mirek": null,
              "mirek_valid": false,
              "mirek_schema": { "mirek_minimum": 153, "mirek_maximum": 500 }
            },
            "color": {
              "xy": { "x": 0.4573, "y": 0.41 },
              "gamut": {
                "red": { "x": 0.6915, "y": 0.3083 },
                "green": { "x": 0.17, "y": 0.7 },
                "blue": { "x": 0.1532, "y": 0.0475 }
              },
              "gamut_type": "C"
            },
            "mode": "normal"
          }]
        }
        """
        let light = try #require(try JSONDecoder().decode(HueResponse<HueLight>.self, from: Data(json.utf8)).data.first)
        #expect(light.name == "Lightstrip")
        #expect(light.isOn)
        #expect(light.dimming?.brightness == 62.45)
        #expect(light.color?.chromaticity == HueXY(x: 0.4573, y: 0.41))
        #expect(light.color?.gamutType == "C")
        #expect(light.color?.gamut?.red == HueXY(x: 0.6915, y: 0.3083))
        #expect(light.colorTemperature?.mirekValid == false)
        #expect(light.activeMirek == nil)
        #expect(light.mode == "normal")
    }

    @Test func `a white-ambiance light in ct mode decodes`() throws {
        let json = """
        {
          "id": "1a2b3c4d-0000-4000-8000-0000000000cc",
          "on": { "on": false },
          "dimming": { "brightness": 100.0 },
          "color_temperature": { "mirek": 366, "mirek_valid": true }
        }
        """
        let light = try JSONDecoder().decode(HueLight.self, from: Data(json.utf8))
        #expect(!light.isOn)
        #expect(light.color == nil)
        #expect(light.activeMirek == 366)
        #expect(light.name == nil)
    }

    @Test func `light updates encode only the fields that are set`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let empty = try encoder.encode(HueLightUpdate())
        #expect(String(bytes: empty, encoding: .utf8) == "{}")

        let update = HueLightUpdate(power: HueOnState(on: true), colorTemperature: .init(mirek: 250))
        let json = try encoder.encode(update)
        #expect(String(bytes: json, encoding: .utf8) == #"{"color_temperature":{"mirek":250},"on":{"on":true}}"#)
    }

    @Test func `entertainment actions encode`() throws {
        let start = try JSONEncoder().encode(HueEntertainmentAction.start)
        let stop = try JSONEncoder().encode(HueEntertainmentAction.stop)
        #expect(String(bytes: start, encoding: .utf8) == #"{"action":"start"}"#)
        #expect(String(bytes: stop, encoding: .utf8) == #"{"action":"stop"}"#)
    }

    // MARK: - Pairing

    @Test func `the pairing request asks for a client key`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(HuePairingRequest.appleTV)
        #expect(String(bytes: json, encoding: .utf8) == #"{"devicetype":"lume#appletv","generateclientkey":true}"#)
    }

    @Test func `a successful pairing yields both keys`() throws {
        let json = #"[{"success":{"username":"fixture-app-key","clientkey":"00112233445566778899AABBCCDDEEFF"}}]"#
        let outcome = try HuePairingOutcome(responseData: Data(json.utf8))
        guard case let .paired(credentials) = outcome else {
            Issue.record("expected .paired, got \(outcome)")
            return
        }
        #expect(credentials.applicationKey == "fixture-app-key")
        #expect(credentials.pskBytes == Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
        ]))
    }

    @Test func `error 101 means the link button wasn't pressed`() throws {
        let json = #"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#
        #expect(try HuePairingOutcome(responseData: Data(json.utf8)) == .linkButtonNotPressed)
    }

    @Test func `other pairing errors keep their type`() throws {
        let json = #"[{"error":{"type":7,"address":"/devicetype","description":"invalid value"}}]"#
        #expect(try HuePairingOutcome(responseData: Data(json.utf8)) == .failed(type: 7, description: "invalid value"))
    }

    @Test func `a success without a client key can't stream`() throws {
        let json = #"[{"success":{"username":"fixture-app-key"}}]"#
        guard case .failed = try HuePairingOutcome(responseData: Data(json.utf8)) else {
            Issue.record("expected .failed")
            return
        }
    }

    @Test(arguments: ["", "abc", "zz112233445566778899aabbccddeeff"])
    func `a malformed client key has no PSK`(clientKey: String) {
        #expect(HueBridgeCredentials(applicationKey: "k", clientKey: clientKey).pskBytes == nil)
    }

    @Test func `credentials never print their keys`() {
        let credentials = HueBridgeCredentials(applicationKey: "secret-app-key", clientKey: "00112233445566778899aabbccddeeff")
        for text in [
            String(describing: credentials),
            String(reflecting: credentials),
            String(describing: HuePairingOutcome.paired(credentials))
        ] {
            #expect(!text.contains("secret-app-key"))
            #expect(!text.contains("00112233"))
        }
    }
}
