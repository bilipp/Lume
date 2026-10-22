import Foundation
@testable import Lume
import LumeCloudKit
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

        #expect(text.contains("Lume Diagnostic Report"))
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

@MainActor
struct DebugLogExporterSyncTests {
    @Test func `icloud lines keep the account and name no server`() {
        let status = CloudSyncStatus()
        status.account = .available
        let lines = DebugLogExporter.cloudSyncLines(status, lumeCloudServer: .custom)
        #expect(lines.first == "Backend: iCloud")
        #expect(lines.contains("Account: available · syncing: no"))
        #expect(lines.contains("Last sync: never"))
        #expect(!lines.joined().contains("server"))
    }

    @Test func `lume cloud lines name server kind, state, last sync and last error`() {
        let status = CloudSyncStatus()
        status.backend = .lumecloud
        status.lumeCloud = .uploading(completed: 2, total: 5)
        status.hasCompletedInitialSync = true
        status.lastReconcile = Date(timeIntervalSince1970: 1_700_000_000)
        status.lastError = LumeCloudErrorDescription.message(for: LumeCloudError.quotaExceeded)
        let lines = DebugLogExporter.cloudSyncLines(status, lumeCloudServer: .staging)
        #expect(lines.first == "Backend: Lume Cloud · server: staging")
        #expect(lines.contains("State: uploading 2 of 5"))
        #expect(lines.contains("Initial sync done: yes"))
        #expect(lines.contains { $0.hasPrefix("Last sync: ") && $0 != "Last sync: never" })
        #expect(lines.contains("Last error: Lume Cloud storage is full. New changes stay on this device."))
    }

    @Test func `off names only the backend`() {
        let status = CloudSyncStatus()
        status.backend = .off
        #expect(DebugLogExporter.cloudSyncLines(status).first == "Backend: off")
    }

    @Test func `every lume cloud state has a label`() {
        let states: [LumeCloudSyncState] = [
            .notJoined, .joined, .syncing, .uploading(completed: 0, total: 1), .revoked,
            .accountDeleted, .rateLimited, .quotaExceeded, .offline
        ]
        #expect(Set(states.map(DebugLogExporter.lumeCloudStateLabel)).count == states.count)
    }

    @Test func `the report carries no lume cloud secret`() async throws {
        let keys = LumeCloudKeys.generate()
        let recoveryKey = LumeCloudRecoveryKey.encode(keys)
        let deviceID = UUID()
        let accountId = "acct_fictional01"
        let pairingCode = "482913"
        // The Kit's `Credentials.authorizationHeader` format (PROTOCOL.md §2).
        let authorizationHeader = "Bearer \(accountId).\(keys.authToken)"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiagnosticJournal(directory: directory)
        let messages: [LumeLogMessage] = [
            "request headers: Authorization: \(authorizationHeader)",
            "opened \("lume://cloud/pair?code=\(pairingCode)")",
            "push failed: \(LumeCloudError.badRequest(message: "rid for \(accountId) on \(deviceID.uuidString)"))",
            "identity: \(keys)",
            "recovery key shown: \(recoveryKey, privacy: .private)",
            "registered device \(deviceID.uuidString, privacy: .private)"
        ]
        for message in messages {
            journal.record(level: .error, category: "Sync", message: message.redacted)
        }

        let suiteName = "report-secrets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(deviceID.uuidString, forKey: LumeCloudSettings.Key.deviceID)
        LumeCloudSettings(defaults: defaults).deviceName = "Fictional Den TV"
        defaults.set(false, forKey: LumeCloudSettings.Key.recoveryKeyViewed)

        let exporter = Self.exporter(journal: journal, defaults: defaults, visibleProblem: "Authorization: \(authorizationHeader)")
        let report = await exporter.makeReport()
        let summary = exporter.compactSummary(maxLength: 10000)
        #expect(report.contains("Backend: Lume Cloud · server: custom"))
        #expect(report.contains("Bearer <redacted>"))

        let secrets = [
            keys.rootKey.base64EncodedString(), Self.base64URL(keys.rootKey),
            keys.authKey.base64EncodedString(), keys.authToken, authorizationHeader,
            recoveryKey, recoveryKey.replacingOccurrences(of: "-", with: ""),
            pairingCode, accountId, deviceID.uuidString, "Fictional Den TV"
        ]
        for secret in secrets {
            #expect(!report.contains(secret), "report leaks \(secret.prefix(4))…")
            #expect(!summary.contains(secret), "summary leaks \(secret.prefix(4))…")
        }
    }

    private static func exporter(journal: DiagnosticJournal, defaults: UserDefaults, visibleProblem: String) -> DebugLogExporter {
        let status = CloudSyncStatus()
        status.backend = .lumecloud
        status.lumeCloud = .joined
        status.lastError = LumeCloudErrorDescription.message(for: LumeCloudError.badRequest(message: "acct_fictional01"))
        var metadata = DebugLogExporter.Metadata(
            appVersion: "1.2.3", buildNumber: "42", platform: "iOS", osVersion: "26.4",
            deviceModel: "iPhone17,1", engineSummary: "KSPlayer"
        )
        metadata.cloudSync = DebugLogExporter.cloudSyncLines(status, lumeCloudServer: .custom)
        metadata.settings = DebugLogExporter.settingsLines(defaults)
        metadata.visibleProblem = visibleProblem
        return DebugLogExporter(metadata: metadata, journal: journal)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
