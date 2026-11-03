//
//  DebugLogExporterHueTests.swift
//  LumeTests
//
//  The diagnostic report's Hue line and the redaction around it: the
//  application key, client key, bridge id, bridge address and area id never
//  reach the report, the compact summary or a redacted log line.
//

import Foundation
@testable import Lume
import Testing

struct DebugLogExporterHueTests {
    private static let applicationKey = "fictionalAppKey0123456789abcdefFICTIONAL"
    private static let clientKey = "0F1E2D3C4B5A69788796A5B4C3D2E1F0"
    private static let bridgeID = "001788fffe6b1c2d"
    private static let bridgeHost = "192.168.178.24"
    private static let areaID = "8d199a37-5ce4-4aae-a60e-db5d0aa27df3"

    private static var secrets: [String] {
        [applicationKey, clientKey, bridgeID, bridgeID.uppercased(), bridgeHost, areaID]
    }

    private static let allErrors: [HueSyncError] = [
        .unsupportedArea,
        .stream(.invalidCredentials), .stream(.localNetworkDenied), .stream(.handshakeFailed),
        .stream(.timedOut), .stream(.connectionLost),
        .bridge(.linkButtonNotPressed), .bridge(.areaInUse), .bridge(.unauthorized), .bridge(.notFound),
        .bridge(.rateLimited), .bridge(.untrustedCertificate), .bridge(.wrongBridge),
        .bridge(.pairingFailed(type: 7)), .bridge(.rejected), .bridge(.server(status: 503)),
        .bridge(.transport(.timedOut)), .bridge(.invalidRequest), .bridge(.invalidResponse), .bridge(.cancelled)
    ]

    @Test func `hue line names paired, state and last error`() {
        #expect(DebugLogExporter.hueLine(paired: false, state: .idle, lastError: nil)
            == "Hue: paired no · idle · last error: none")
        #expect(DebugLogExporter.hueLine(paired: true, state: .streaming, lastError: .stream(.handshakeFailed))
            == "Hue: paired yes · streaming · last error: stream handshake failed")
        #expect(DebugLogExporter.hueLine(paired: true, state: .areaInUse, lastError: nil)
            == "Hue: paired yes · area in use · last error: none")
    }

    @Test func `every hue error has a hand-written description`() {
        let descriptions = Self.allErrors.map(\.logDescription)
        #expect(Set(descriptions).count == descriptions.count)
        for error in Self.allErrors {
            let described = LogRedaction.describe(error)
            #expect(described.hasPrefix("HueSyncError: "))
            #expect(!described.contains("NSError"))
            #expect(!described.contains("Lume."))
        }
    }

    @Test func `hue values never print their secrets`() {
        let credentials = HueBridgeCredentials(applicationKey: Self.applicationKey, clientKey: Self.clientKey)
        let secrets = HueBridgeSecrets(credentials: credentials, certificatePin: Data([1, 2, 3]))
        let address = HueBridgeAddress(id: Self.bridgeID, host: Self.bridgeHost)
        let messages: [LumeLogMessage] = [
            "credentials \(credentials)",
            "secrets \(String(reflecting: secrets))",
            "bridge \(address, privacy: .public)",
            "bridge \(String(reflecting: address))",
            "dumped \(String(describing: Mirror(reflecting: address).children.map(\.value)))"
        ]
        for message in messages {
            for secret in Self.secrets {
                #expect(!message.redacted.contains(secret), "log leaks \(secret.prefix(4))…")
            }
        }
    }

    @Test func `the report carries no hue secret`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hue-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiagnosticJournal(directory: directory)
        let credentials = HueBridgeCredentials(applicationKey: Self.applicationKey, clientKey: Self.clientKey)
        let address = HueBridgeAddress(id: Self.bridgeID, host: Self.bridgeHost)
        let messages: [LumeLogMessage] = [
            "Hue session setup failed: \(LogRedaction.describe(HueBridgeError.unauthorized), privacy: .public)",
            "Hue stream ended: \(LogRedaction.describe(HueStreamTransportError.handshakeFailed), privacy: .public)",
            "paired \(address, privacy: .public) with \(credentials, privacy: .public)",
            "request \("https://\(Self.bridgeHost)/clip/v2/resource/entertainment_configuration/\(Self.areaID)")"
        ]
        for message in messages {
            journal.record(level: .error, category: "Player", message: message.redacted)
        }

        let suiteName = "hue-report-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Self.bridgeHost, forKey: PlayerSettings.Hue.bridgeHostKey)
        defaults.set(Self.bridgeID, forKey: PlayerSettings.Hue.bridgeIDKey)
        PlayerSettings.Hue.setEntertainmentAreaID(Self.areaID, in: defaults)
        PlayerSettings.Hue.setSelection(.high, in: defaults)
        PlayerSettings.Hue.saveRestoreSnapshot(
            HueLightSnapshot(lights: [.init(lightID: Self.areaID, isOn: true, brightness: 40, color: .mirek(300))]),
            in: defaults
        )

        var metadata = DebugLogExporter.Metadata(
            appVersion: "1.2.3", buildNumber: "42", platform: "tvOS", osVersion: "26.4",
            deviceModel: "AppleTV14,1", engineSummary: "KSPlayer"
        )
        metadata.hue = DebugLogExporter.hueLine(paired: true, state: .streaming, lastError: .bridge(.unauthorized))
        metadata.settings = DebugLogExporter.settingsLines(defaults)
        let exporter = DebugLogExporter(metadata: metadata, journal: journal)

        let report = await exporter.makeReport()
        let summary = exporter.compactSummary(maxLength: 10000)

        #expect(report.contains("Hue: paired yes · streaming · last error: bridge unauthorized"))
        #expect(report.contains("player.hue.enabled = on"))
        #expect(report.contains("player.hue.intensity = high"))
        #expect(!report.contains("hue.bridge."))
        #expect(!report.contains("hue.restoreSnapshot"))
        #expect(!report.contains("hue.entertainmentArea"))
        for secret in Self.secrets {
            #expect(!report.contains(secret), "report leaks \(secret.prefix(4))…")
            #expect(!summary.contains(secret), "summary leaks \(secret.prefix(4))…")
        }
    }
}
