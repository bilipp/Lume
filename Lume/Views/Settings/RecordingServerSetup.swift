//
//  RecordingServerSetup.swift
//  Lume
//
//  Copy and state shared by the Recording Server settings page
//  (iOS / macOS / visionOS) and its tvOS pane, so both platforms show the same
//  disclosure and disclaimer, acknowledge it once, and pair, test and remove
//  the same way.
//

import Foundation
import LumeRecorderKit
import Observation

enum RecordingServerSetup {
    static let disclosureAcknowledgedKey = "recordingServer.disclosureAcknowledged"
    /// tvOS: whether the Live TV category rail lists Recordings (below
    /// Favorites and Recently Watched). Off unless the user turns it on in
    /// Settings › Live TV; the library is always a row there as well.
    static let showsRecordingsInLiveTVRailKey = "lume.liveTV.showsRecordingsInRail"
    static let showsRecordingsInLiveTVRailDefault = false

    /// The paywall's own line for the feature, so the two never drift apart.
    static var intro: String {
        String(localized: PremiumFeature.recordingServer.subtitle)
    }

    static var disclosure: String {
        String(localized: "To record, Lume sends the recording server the stream address the player uses. For Xtream playlists it includes your provider username and password.")
    }

    static var connectionNote: String {
        String(localized: "The server fetches the stream from its own IP address, so if your provider allows only one connection at a time, a recording may fail while you're watching.")
    }

    static var disclaimer: String {
        String(localized: "Only record content you're entitled to. You're responsible for following your provider's terms and the law where you live.")
    }

    /// Next to the link (a QR code on tvOS) to SupportInfo.recorderGuide.
    static var setupGuideNote: String {
        String(localized: "Step-by-step instructions for setting up a LumeRecorder server.")
    }

    static var removeFooter: String {
        String(localized: "Removing the server keeps its recordings and schedules on the server.")
    }

    static func removeConfirmationTitle(_ serverName: String) -> String {
        String(
            localized: "Remove “\(serverName)”?",
            comment: "Confirmation title before removing the paired recording server; the argument is its name."
        )
    }

    static var removeConfirmationMessage: String {
        String(localized: "Lume forgets this server on all your devices. Recordings and schedules stay on the server.")
    }

    /// Shown after a removal whose revoke didn't reach the server.
    static var revokeFailedNote: String {
        String(localized: "Lume couldn't reach the server, so it may still list this device. Pair again or remove it there.")
    }

    static var localNetworkUnavailable: String {
        String(localized: "Lume can't search the local network. Allow Local Network access for Lume in the system settings, or enter the server's address manually.")
    }

    static func diskSummary(_ status: ServerStatus?) -> String {
        guard let status else { return "—" }
        let free = status.freeDiskBytes.formatted(.byteCount(style: .file))
        let total = status.totalDiskBytes.formatted(.byteCount(style: .file))
        return String(
            localized: "\(free) free of \(total)",
            comment: "Recording server disk space: free bytes, then total bytes (e.g. “120 GB free of 500 GB”)."
        )
    }
}

// MARK: - Access

/// Which recording rows the Live TV settings page offers and what each opens,
/// on every platform. The page itself is free (its layout switch is); Lume Pro
/// gates recording. A lapsed subscriber still reaches a paired server's page to
/// remove it — pairing a new one is what needs Lume Pro.
struct RecordingSettingsAccess: Equatable {
    /// Lume Pro unlocks recording.
    let isUnlocked: Bool
    /// Any server row is stored, usable or not: the page has something to
    /// manage even without Lume Pro.
    let hasServers: Bool
    /// A usable server is paired.
    let isPaired: Bool

    /// The Recording Server row opens the paywall instead of its page.
    var serverRowOpensPaywall: Bool {
        !isUnlocked && !hasServers
    }

    /// The Recording Server row carries the crown.
    var serverRowShowsBadge: Bool {
        !isUnlocked
    }

    /// The Recordings row is offered at all; the toolbar button and the tvOS
    /// rail entry follow the same rule.
    var showsRecordingsRow: Bool {
        isPaired
    }

    /// The Recordings row shows the crown and opens the paywall instead of
    /// the library.
    var recordingsRowOpensPaywall: Bool {
        !isUnlocked
    }
}

// MARK: - Pairing

/// Checks a server's identity and API version, then exchanges the six-digit
/// code the server prints for a token, stored as the synced pairing.
@MainActor
@Observable
final class RecordingServerPairingModel {
    static let codeLength = 6

    var address = ""
    var code = ""
    private(set) var info: ServerInfo?
    private(set) var checkedURL: URL?
    private(set) var isChecking = false
    private(set) var isPairing = false
    private(set) var errorMessage: String?

    var canPair: Bool {
        info != nil && code.count == Self.codeLength && !isPairing
    }

    /// A different address invalidates whatever the last one answered.
    func addressDidChange() {
        info = nil
        checkedURL = nil
        errorMessage = nil
    }

    func sanitizeCode() {
        let digits = String(code.filter { $0.isASCII && $0.isNumber }.prefix(Self.codeLength))
        if digits != code {
            code = digits
        }
    }

    /// Checks the typed address; `false` when it doesn't parse or answer.
    @discardableResult
    func connectToAddress() async -> Bool {
        errorMessage = nil
        guard let baseURL = LumeRecorderClient.normalizedBaseURL(from: address) else {
            errorMessage = RecordingServerError.invalidAddress.localizedDescription
            return false
        }
        return await check(baseURL)
    }

    /// `false` when the server doesn't answer as one this build can pair with.
    @discardableResult
    func check(_ baseURL: URL) async -> Bool {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            info = try await RecordingServerStore.shared.serverInfo(baseURL: baseURL)
            checkedURL = baseURL
            return true
        } catch {
            info = nil
            checkedURL = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// `true` once the pairing is stored.
    func pair() async -> Bool {
        guard let checkedURL, canPair else { return false }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            try await RecordingServerStore.shared.pair(baseURL: checkedURL, code: code)
            return true
        } catch {
            if error == .invalidPairingCode {
                code = ""
            }
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Paired server

/// The paired server's identity, Test Connection and Remove Server.
@MainActor
@Observable
final class RecordingServerConnectionModel {
    enum TestResult {
        case success
        case failure(String)
    }

    private(set) var info: ServerInfo?
    private(set) var isTesting = false
    private(set) var testResult: TestResult?
    private(set) var isRemoving = false

    private var store: RecordingServerStore {
        .shared
    }

    func loadInfo(for server: RecordingServerConfig) async {
        guard let baseURL = server.endpoint?.baseURL else { return }
        info = try? await store.serverInfo(baseURL: baseURL)
    }

    func testConnection(to server: RecordingServerConfig) async {
        guard !isTesting, let baseURL = server.endpoint?.baseURL else { return }
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            info = try await store.serverInfo(baseURL: baseURL)
        } catch {
            testResult = .failure(error.localizedDescription)
            return
        }
        await store.refresh()
        await store.refreshStatus()
        if case let .unreachable(error) = store.reachability {
            testResult = .failure(error.localizedDescription)
        } else {
            testResult = .success
        }
    }

    /// Removes the server on every device after a best-effort revoke; `nil`
    /// while a removal is already running.
    func remove(_ server: RecordingServerConfig) async -> RecordingServerStore.Removal? {
        guard !isRemoving else { return nil }
        isRemoving = true
        defer { isRemoving = false }
        return await store.removeServer(id: server.id)
    }
}
