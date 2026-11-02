//
//  RecordingServerConfigService.swift
//  Lume
//
//  The app-facing reader/writer for the paired recording server, stored as
//  `SyncedRecordingServer` in the CloudKit mirror (`CloudUserData.store`).
//
//  Read and written directly over the cloud store's main context — never a
//  `@Query` against the mirror (its CloudKit churn would invalidate the browse
//  `@Query`s; see the two-container split), the same way `SportsFollowService`
//  owns the sports follows. Writes happen only from settings/pairing actions,
//  never during playback.
//

import Foundation
import Observation
import os
import SwiftData

/// A credential-carrying snapshot of one `SyncedRecordingServer` row.
nonisolated struct RecordingServerConfig: Identifiable, Hashable {
    let id: UUID
    let kindRaw: String
    let name: String
    let baseURL: String
    let serverID: UUID?
    let deviceID: UUID?
    let isEnabled: Bool
    let updatedAt: Date
    /// `nil` when the kind is unsupported, the address is unusable or the
    /// device was never paired — such a config can't be talked to.
    let endpoint: RecordingServerEndpoint?

    var kind: RecordingServerKind? {
        RecordingServerKind(rawValue: kindRaw)
    }

    /// The `RecordingProgressStore` namespace of this server's recordings.
    var progressNamespace: String? {
        kind.flatMap { RecordingProgressStore.namespace(kind: $0, serverID: serverID ?? id) }
    }
}

@MainActor
@Observable
final class RecordingServerConfigService {
    static let shared = RecordingServerConfigService()

    /// Every synced server row, newest first. Rows from a newer build with an
    /// unknown kind are kept (and shown as unsupported), never rewritten.
    private(set) var servers: [RecordingServerConfig] = []

    @ObservationIgnored private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        reload()
    }

    /// Follow a backend switch onto `container`'s mirror store.
    func repoint(container: ModelContainer) {
        configure(container: container)
    }

    /// An iCloud remote change doesn't land here: it always runs a reconcile,
    /// and the app reloads on `lastReconcile`.
    func mirrorDidChange() {
        reload()
    }

    private var context: ModelContext? {
        container?.mainContext
    }

    // MARK: - Reads

    /// The server Record actions and the library talk to. v1 manages a single
    /// server, so this is the newest enabled, reachable-in-principle config.
    var activeServer: RecordingServerConfig? {
        servers.first { $0.isEnabled && $0.endpoint != nil }
    }

    var isPaired: Bool {
        activeServer != nil
    }

    /// Every row but the active one: an unknown backend kind from a newer
    /// build, or a pairing without a usable address or token.
    var unusableServers: [RecordingServerConfig] {
        let activeID = activeServer?.id
        return servers.filter { $0.id != activeID }
    }

    func server(id: UUID) -> RecordingServerConfig? {
        servers.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Store a fresh LumeRecorder pairing.
    @discardableResult
    func savePairing(
        _ pairing: RecordingServerPairing,
        kind: RecordingServerKind,
        baseURL: URL
    ) -> RecordingServerConfig? {
        savePairing(
            serverID: pairing.server.id,
            name: pairing.server.name,
            kind: kind,
            baseURL: baseURL,
            token: pairing.token,
            deviceID: pairing.deviceID
        )
    }

    /// Store a fresh pairing. Re-pairing a server already on file (same kind
    /// and `serverID`) updates that row instead of adding a second one.
    ///
    /// Lume talks to one recording server at a time, so this forgets every
    /// other server of a kind this build knows — without contacting it. Rows of
    /// an unknown kind belong to a newer build and are left untouched.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    func savePairing(
        serverID: UUID,
        name: String,
        kind: RecordingServerKind,
        baseURL: URL,
        token: String,
        deviceID: UUID?
    ) -> RecordingServerConfig? {
        guard let context else { return nil }
        let rows = fetchRows()
        let row = rows.first { $0.kindRaw == kind.rawValue && $0.serverID == serverID } ?? {
            let inserted = SyncedRecordingServer(kind: kind, name: name, baseURL: baseURL.absoluteString)
            context.insert(inserted)
            return inserted
        }()
        for other in rows where other !== row && other.kind != nil {
            SyncMirrorDeletionLog.shared.delete(other, in: context)
        }
        row.kindRaw = kind.rawValue
        row.name = name
        row.baseURL = baseURL.absoluteString
        row.serverID = serverID
        row.deviceID = deviceID
        row.token = token
        row.isEnabled = true
        row.updatedAt = Date()
        let id = row.id
        save(context, action: "save pairing")
        return server(id: id)
    }

    /// Edit the user-facing parts of a config. `nil` leaves a field unchanged.
    func update(id: UUID, name: String? = nil, baseURL: URL? = nil, isEnabled: Bool? = nil) {
        guard let context else { return }
        let rows = fetchRows().filter { $0.id == id }
        guard !rows.isEmpty else { return }
        let now = Date()
        for row in rows {
            if let name {
                row.name = name
            }
            if let baseURL {
                row.baseURL = baseURL.absoluteString
            }
            if let isEnabled {
                row.isEnabled = isEnabled
            }
            row.updatedAt = now
        }
        save(context, action: "update")
    }

    /// Remove a config locally (and, through the mirror, on every device).
    /// Anything scheduled on the server is left untouched.
    func delete(id: UUID) {
        guard let context else { return }
        let rows = fetchRows().filter { $0.id == id }
        guard !rows.isEmpty else { return }
        for row in rows {
            SyncMirrorDeletionLog.shared.delete(row, in: context)
        }
        save(context, action: "delete")
    }

    // MARK: - Reload

    /// Re-read every row. Called on configure, after each mutation, after each
    /// reconcile and when the mirror changes or is swapped. Leaves `servers`
    /// alone when nothing changed, so CloudKit's remote-change churn doesn't
    /// re-render the settings screens.
    func reload() {
        let latest = fetchRows().map(Self.snapshot)
        if latest != servers {
            servers = latest
        }
    }

    private func fetchRows() -> [SyncedRecordingServer] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<SyncedRecordingServer>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func save(_ context: ModelContext, action: String) {
        do {
            try context.save()
        } catch {
            let reason = LogRedaction.describe(error)
            Logger.recording.error("Recording server config \(action, privacy: .public) failed: \(reason, privacy: .public)")
        }
        reload()
    }

    private static func snapshot(_ row: SyncedRecordingServer) -> RecordingServerConfig {
        let endpoint = row.kind.flatMap { kind in
            storedBaseURL(row.baseURL).map { RecordingServerEndpoint(kind: kind, baseURL: $0, token: row.token) }
        }
        .flatMap { $0.hasUsableCredential ? $0 : nil }
        return RecordingServerConfig(
            id: row.id,
            kindRaw: row.kindRaw,
            name: row.name,
            baseURL: row.baseURL,
            serverID: row.serverID,
            deviceID: row.deviceID,
            isEnabled: row.isEnabled,
            updatedAt: row.updatedAt,
            endpoint: endpoint
        )
    }

    /// Stored addresses were normalized when saved (and may be a bracketed IPv6
    /// literal the normalizer can't round-trip), so only sanity-check them here.
    private static func storedBaseURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

extension RecordingServerConfigService: SyncMirrorConsumer {}
