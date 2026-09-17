import Foundation
@testable import Lume
import OSLog
import Testing

struct DebugLogExporterTests {
    private func sampleMetadata() -> DebugLogExporter.Metadata {
        DebugLogExporter.Metadata(
            appVersion: "1.2.3",
            buildNumber: "42",
            platform: "iOS",
            osVersion: "Version 26.4 (Build 23A340)",
            deviceModel: "iPhone17,1",
            engineSummary: "KSPlayer › VLCKit › AVPlayer"
        )
    }

    @Test func `header carries the app, device and engine context`() {
        let exporter = DebugLogExporter(metadata: sampleMetadata())
        let text = exporter.header(now: Date(timeIntervalSince1970: 0)).joined(separator: "\n")

        #expect(text.contains("Lume Diagnostic Log"))
        #expect(text.contains("App: Lume 1.2.3 (build 42)"))
        #expect(text.contains("Platform: iOS Version 26.4 (Build 23A340)"))
        #expect(text.contains("Device: iPhone17,1"))
        #expect(text.contains("Player engines: KSPlayer › VLCKit › AVPlayer"))
    }

    @Test func `level labels map every case`() {
        #expect(DebugLogExporter.label(for: .debug) == "debug")
        #expect(DebugLogExporter.label(for: .info) == "info")
        #expect(DebugLogExporter.label(for: .notice) == "notice")
        #expect(DebugLogExporter.label(for: .error) == "error")
        #expect(DebugLogExporter.label(for: .fault) == "fault")
        #expect(DebugLogExporter.label(for: .undefined) == "—")
    }

    @Test func `signpost labels map every case`() {
        #expect(DebugLogExporter.signpostLabel(for: .intervalBegin) == "signpost-begin")
        #expect(DebugLogExporter.signpostLabel(for: .intervalEnd) == "signpost-end")
        #expect(DebugLogExporter.signpostLabel(for: .event) == "signpost-event")
        #expect(DebugLogExporter.signpostLabel(for: .undefined) == "signpost")
    }

    @Test func `device model is never empty`() {
        #expect(!DebugLogExporter.deviceModel.isEmpty)
    }

    @MainActor
    @Test func `current metadata reads real app and engine values`() {
        let metadata = DebugLogExporter.currentMetadata()
        #expect(!metadata.appVersion.isEmpty)
        #expect(!metadata.osVersion.isEmpty)
        // The engine summary always resolves to the full fallback list.
        for engine in PlayerEngineKind.allCases {
            #expect(metadata.engineSummary.contains(engine.displayName))
        }
    }
}

/// Serialized: these mutate the shared `UserDefaults` diagnostics keys.
@Suite(.serialized)
struct DebugLogSettingsTests {
    private func withCleanState(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: DebugLogSettings.enabledKey)
        let savedSince = defaults.object(forKey: DebugLogSettings.enabledSinceKey)
        defaults.removeObject(forKey: DebugLogSettings.enabledKey)
        defaults.removeObject(forKey: DebugLogSettings.enabledSinceKey)
        defer {
            defaults.set(savedEnabled, forKey: DebugLogSettings.enabledKey)
            defaults.set(savedSince, forKey: DebugLogSettings.enabledSinceKey)
        }
        body()
    }

    @Test func `enabled flag reflects the stored bool`() {
        withCleanState {
            #expect(!DebugLogSettings.isEnabled)
            UserDefaults.standard.set(true, forKey: DebugLogSettings.enabledKey)
            #expect(DebugLogSettings.isEnabled)
        }
    }

    @Test func `enabledSince is nil until logging is marked enabled`() {
        withCleanState {
            #expect(DebugLogSettings.enabledSince == nil)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            DebugLogSettings.markEnabled(at: now)
            let since = DebugLogSettings.enabledSince
            #expect(since != nil)
            #expect(abs((since ?? .distantPast).timeIntervalSince(now)) < 0.001)
        }
    }
}
