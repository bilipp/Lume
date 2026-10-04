//
//  RecordingServerSettingsView.swift
//  Lume
//
//  The iOS / macOS / visionOS Recording Server page, behind Settings › Live
//  TV: find a LumeRecorder server
//  on the network (or type its address), pair with the code it prints, and,
//  once paired, its status with Test Connection, Unpair and Remove. The pairing
//  is a synced `SyncedRecordingServer` row, so one pairing serves every device
//  on the account.
//
//  Pairing needs Lume Pro. A lapsed subscriber still reaches the page while a
//  server is paired, to see its status and unpair or remove it.
//
//  Bonjour browsing runs only while the setup list is on screen, so the
//  local-network prompt appears when the user is looking for a server and not
//  before.
//

#if !os(tvOS)

    import LumeRecorderKit
    import SwiftUI

    struct RecordingServerSettingsView: View {
        @State private var configService = RecordingServerConfigService.shared
        @State private var store = RecordingServerStore.shared
        @State private var discovery = RecordingServerDiscovery()
        @State private var pairingTarget: RecordingServerPairingTarget?
        @State private var showsPaywall = false
        @AppStorage(RecordingServerSetup.disclosureAcknowledgedKey) private var disclosureAcknowledged = false

        private var browsesForServers: Bool {
            store.isUnlocked && configService.activeServer == nil && disclosureAcknowledged
        }

        var body: some View {
            List {
                if let server = configService.activeServer {
                    RecordingServerPairedSection(server: server, isLocked: !store.isUnlocked) { baseURL in
                        pairingTarget = RecordingServerPairingTarget(baseURL: baseURL)
                    }
                } else if !store.isUnlocked {
                    lockedSection
                } else if disclosureAcknowledged {
                    discoveredServersSection
                } else {
                    disclosureSection
                }
                if !configService.unusableServers.isEmpty {
                    otherServersSection
                }
            }
            .platformNavigationTitle("Recording Server")
            .sheet(item: $pairingTarget) { target in
                RecordingServerPairingSheet(target: target)
            }
            .paywall(isPresented: $showsPaywall, highlight: .recordingServer)
            .task(id: browsesForServers) {
                if browsesForServers {
                    discovery.start()
                } else {
                    discovery.stop()
                }
            }
            .onDisappear { discovery.stop() }
        }

        // MARK: - Locked

        /// No server paired and no Lume Pro: pairing opens the paywall.
        private var lockedSection: some View {
            Section {
                Button {
                    showsPaywall = true
                } label: {
                    Label("Pair Recording Server", systemImage: "crown")
                }
            } footer: {
                Text(RecordingServerSetup.intro)
            }
        }

        // MARK: - Disclosure

        private var disclosureSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Before You Pair", systemImage: "exclamationmark.shield")
                        .font(.headline)
                    Text(RecordingServerSetup.disclosure)
                    Text(RecordingServerSetup.connectionNote)
                    Text(RecordingServerSetup.disclaimer)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button {
                    disclosureAcknowledged = true
                } label: {
                    Label("I Understand", systemImage: "checkmark.circle")
                }
            } footer: {
                Text(RecordingServerSetup.intro)
            }
        }

        // MARK: - Discovery

        private var discoveredServersSection: some View {
            Section {
                ForEach(discovery.servers) { server in
                    discoveredServerRow(server)
                }
                if discovery.servers.isEmpty {
                    discoveryStatusRow
                }
                Button {
                    pairingTarget = .manual
                } label: {
                    Label("Enter Address Manually", systemImage: "keyboard")
                }
            } header: {
                Text("Servers on This Network")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RecordingServerSetup.intro)
                    Text(RecordingServerSetup.disclaimer)
                }
            }
        }

        private func discoveredServerRow(_ server: DiscoveredRecordingServer) -> some View {
            Button {
                guard let baseURL = server.baseURL else { return }
                pairingTarget = RecordingServerPairingTarget(baseURL: baseURL)
            } label: {
                HStack {
                    Label(server.name, systemImage: "server.rack")
                    Spacer(minLength: 8)
                    if server.baseURL == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else if let version = server.version {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(server.baseURL == nil)
        }

        @ViewBuilder
        private var discoveryStatusRow: some View {
            switch discovery.state {
            case .unavailable:
                Text(RecordingServerSetup.localNetworkUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .waitingForLocalNetwork:
                // Still browsing: once Local Network access is allowed the
                // search resumes by itself.
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for Local Network access…")
                        .foregroundStyle(.secondary)
                }
            case .browsing, .idle:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching for recording servers…")
                        .foregroundStyle(.secondary)
                }
            }
        }

        // MARK: - Unsupported rows

        private var otherServersSection: some View {
            Section {
                ForEach(configService.unusableServers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name.isEmpty ? String(localized: "Recording Server") : server.name)
                            Text(server.kind == nil
                                ? String(localized: "Not supported by this version of Lume")
                                : String(localized: "Not paired"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive) {
                            store.remove(id: server.id)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Other Servers")
            }
        }
    }

    // MARK: - Paired server

    /// The paired server's identity, disk and recording status, and its actions.
    private struct RecordingServerPairedSection: View {
        let server: RecordingServerConfig
        /// Lume Pro has lapsed: only the server's identity and Unpair / Remove.
        let isLocked: Bool
        /// Re-pairs with the same server once its token was revoked.
        let repair: (_ baseURL: URL) -> Void

        @State private var store = RecordingServerStore.shared
        @State private var connection = RecordingServerConnectionModel()
        @State private var confirmsUnpair = false
        @State private var confirmsRemove = false

        var body: some View {
            Section {
                identityRow
                    .task(id: server.id) {
                        async let info: Void = connection.loadInfo(for: server)
                        async let recordings: Void = store.refresh()
                        await store.refreshStatus()
                        _ = await (info, recordings)
                    }
                LabeledContent("Version", value: connection.info?.version ?? "—")
                if !isLocked {
                    LabeledContent("Free Disk Space", value: RecordingServerSetup.diskSummary(store.status))
                    LabeledContent("Active Recordings", value: store.status.map { "\($0.activeRecordings)" } ?? "—")
                }
                if !isLocked, store.reachability.needsRepairing, let baseURL = server.endpoint?.baseURL {
                    Button {
                        repair(baseURL)
                    } label: {
                        Label("Pair Again", systemImage: "key")
                    }
                }
            } header: {
                Text("Paired Server")
            } footer: {
                if case let .unreachable(error) = store.reachability {
                    Text(error.localizedDescription)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if !isLocked {
                    Button {
                        Task { await connection.testConnection(to: server) }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer(minLength: 8)
                            if connection.isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(connection.isTesting)
                }

                Button(role: .destructive) {
                    confirmsUnpair = true
                } label: {
                    HStack {
                        Label("Unpair", systemImage: "minus.circle")
                        Spacer(minLength: 8)
                        if connection.isUnpairing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(connection.isUnpairing)
                .confirmationDialog(
                    "Unpair this recording server?",
                    isPresented: $confirmsUnpair,
                    titleVisibility: .visible
                ) {
                    Button("Unpair", role: .destructive) {
                        Task { await connection.unpair(server) }
                    }
                    Button("Cancel", role: .cancel) {}
                }

                Button(role: .destructive) {
                    confirmsRemove = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .confirmationDialog(
                    "Remove this recording server from Lume?",
                    isPresented: $confirmsRemove,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        store.remove(id: server.id)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    switch connection.testResult {
                    case .success:
                        Text("The recording server is reachable.")
                            .foregroundStyle(.green)
                    case let .failure(message):
                        Text(message)
                            .foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                    if let actionError = connection.actionError {
                        Text(actionError)
                            .foregroundStyle(.red)
                    }
                    Text(RecordingServerSetup.unpairFooter)
                    Text(RecordingServerSetup.disclaimer)
                }
            }
        }

        private var identityRow: some View {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.tint)
                    .font(.title3)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.info?.name ?? server.name)
                    if let host = server.endpoint?.baseURL.host() {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                reachabilityBadge
            }
        }

        @ViewBuilder
        private var reachabilityBadge: some View {
            switch store.reachability {
            case .reachable:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Connected")
            case .unreachable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Not connected")
            case .unknown:
                EmptyView()
            }
        }
    }

#endif
