//
//  TVRecordingServerSettingsView.swift
//  Lume
//
//  The tvOS Recording Server pane, drilled into from Settings › Live TV and
//  shown in place in SettingsView's detail column. Every
//  step — the disclosure, servers found on the network, a typed address, the
//  pairing code and the paired server's status — replaces the pane's content in
//  place, inside the detail column's persistent scroll view: a push would hide
//  the tab bar and strand remote focus.
//
//  Each step a button opens hands focus to the new step's first control with a
//  deferred `@FocusState` write. Focus is never moved on appear: the pane
//  renders while the sidebar holds focus, and taking it there would pull focus
//  out of the sidebar as the user scrolls past this category.
//

#if os(tvOS)

    import LumeRecorderKit
    import SwiftUI

    /// Where the pane is drilled in to; `nil` is its top level. Owned by
    /// SettingsView, which clears it when focus returns to the sidebar, like
    /// its other drill-ins.
    enum TVRecordingServerRoute: Hashable {
        /// Typing the address of a server Bonjour didn't find.
        case manualAddress
        /// Pairing with the server at this address: a discovered one, or the
        /// paired one after it revoked the token.
        case server(URL)

        var baseURL: URL? {
            if case let .server(url) = self { url } else { nil }
        }
    }

    /// The pane's controls that a step change hands focus to.
    enum TVRecordingServerFocus: Hashable {
        /// The locked pane's Pair Recording Server (opens the paywall).
        case lockedPair
        case acknowledge
        case manualAddress
        case testConnection
    }

    struct TVRecordingServerSettingsView: View {
        @Binding var route: TVRecordingServerRoute?

        @State private var configService = RecordingServerConfigService.shared
        @State private var store = RecordingServerStore.shared
        @State private var discovery = RecordingServerDiscovery()
        @State private var showPaywall = false
        @AppStorage(RecordingServerSetup.disclosureAcknowledgedKey) private var disclosureAcknowledged = false
        @FocusState private var focus: TVRecordingServerFocus?

        private var browsesForServers: Bool {
            store.isUnlocked && disclosureAcknowledged && configService.activeServer == nil && route == nil
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 36) {
                if let route, store.isUnlocked {
                    TVRecordingServerPairingStep(baseURL: route.baseURL) {
                        self.route = nil
                        moveFocus(to: .testConnection)
                    } onCancel: {
                        self.route = nil
                        moveFocus(to: configService.activeServer == nil ? setupFocus : .testConnection)
                    }
                } else if let server = configService.activeServer {
                    // Also for a lapsed subscriber, who must still be able to
                    // unpair or remove it.
                    TVRecordingServerPairedSection(server: server, isLocked: !store.isUnlocked, focus: $focus) { baseURL in
                        route = .server(baseURL)
                    } onRemoved: {
                        moveFocus(to: setupFocus)
                    }
                } else if !store.isUnlocked {
                    locked
                } else if disclosureAcknowledged {
                    discoveredServers
                } else {
                    disclosure
                }

                if route == nil || !store.isUnlocked, !configService.unusableServers.isEmpty {
                    otherServersSection
                }
            }
            .paywall(isPresented: $showPaywall, highlight: .recordingServer)
            .task(id: browsesForServers) {
                if browsesForServers {
                    discovery.start()
                } else {
                    discovery.stop()
                }
            }
            .onDisappear { discovery.stop() }
        }

        /// The first control of the unpaired pane: a pairing synced from another
        /// device leaves this one's disclosure unacknowledged.
        private var setupFocus: TVRecordingServerFocus {
            if !store.isUnlocked { return .lockedPair }
            return disclosureAcknowledged ? .manualAddress : .acknowledge
        }

        /// Defers the write past the render that inserts the target, which
        /// would otherwise drop it.
        private func moveFocus(to target: TVRecordingServerFocus) {
            Task { @MainActor in focus = target }
        }

        // MARK: - Locked

        private var locked: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Recording Server")

                Text(RecordingServerSetup.intro)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "crown")
                            .font(.system(size: 22, weight: .medium))
                        Text("Pair Recording Server")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .focused($focus, equals: .lockedPair)
            }
        }

        // MARK: - Disclosure

        private var disclosure: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Before You Pair")

                VStack(alignment: .leading, spacing: 14) {
                    Text(RecordingServerSetup.intro)
                    Text(RecordingServerSetup.disclosure)
                    Text(RecordingServerSetup.connectionNote)
                    Text(RecordingServerSetup.disclaimer)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 24))
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    disclosureAcknowledged = true
                    moveFocus(to: .manualAddress)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 22, weight: .medium))
                        Text("I Understand")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .focused($focus, equals: .acknowledge)
            }
        }

        // MARK: - Discovery

        private var discoveredServers: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Servers on This Network")

                ForEach(discovery.servers) { server in
                    discoveredServerRow(server)
                }
                if discovery.servers.isEmpty {
                    discoveryStatus
                }

                Button {
                    route = .manualAddress
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 22, weight: .medium))
                        Text("Enter Address Manually")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .focused($focus, equals: .manualAddress)

                VStack(alignment: .leading, spacing: 8) {
                    Text(RecordingServerSetup.intro)
                    Text(RecordingServerSetup.disclaimer)
                }
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 8)
            }
        }

        private func discoveredServerRow(_ server: DiscoveredRecordingServer) -> some View {
            Button {
                guard let baseURL = server.baseURL else { return }
                route = .server(baseURL)
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .medium))
                    Text(verbatim: server.name)
                    Spacer(minLength: 0)
                    if server.baseURL == nil {
                        ProgressView()
                    } else if let version = server.version {
                        Text(verbatim: version)
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .disabled(server.baseURL == nil)
        }

        @ViewBuilder
        private var discoveryStatus: some View {
            switch discovery.state {
            case .unavailable:
                Text(RecordingServerSetup.localNetworkUnavailable)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, TVSettingsMetrics.rowVPadding)
            case .waitingForLocalNetwork:
                // Still browsing: once Local Network access is allowed the
                // search resumes by itself.
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Waiting for Local Network access…")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: TVSettingsMetrics.rowFontSize))
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.vertical, TVSettingsMetrics.rowVPadding)
            case .browsing, .idle:
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Searching for recording servers…")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: TVSettingsMetrics.rowFontSize))
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.vertical, TVSettingsMetrics.rowVPadding)
            }
        }

        // MARK: - Unsupported rows

        private var otherServersSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Other Servers")

                ForEach(configService.unusableServers) { server in
                    Button {
                        store.remove(id: server.id)
                        moveFocus(to: configService.activeServer == nil ? setupFocus : .testConnection)
                    } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name.isEmpty ? String(localized: "Recording Server") : server.name)
                                Text(server.kind == nil
                                    ? String(localized: "Not supported by this version of Lume")
                                    : String(localized: "Not paired"))
                                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                                    .opacity(0.7)
                            }
                            Spacer(minLength: 0)
                            Text("Remove")
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
                }
            }
        }
    }

    // MARK: - Paired server

    /// The paired server's identity, disk and recording status, and its actions.
    private struct TVRecordingServerPairedSection: View {
        let server: RecordingServerConfig
        /// Lume Pro has lapsed: only the server's identity and Unpair / Remove.
        let isLocked: Bool
        var focus: FocusState<TVRecordingServerFocus?>.Binding
        /// Re-pairs with the same server once its token was revoked.
        let repair: (_ baseURL: URL) -> Void
        /// The pairing is gone (unpaired or removed); the pane falls back to
        /// discovery.
        let onRemoved: () -> Void

        @State private var store = RecordingServerStore.shared
        @State private var connection = RecordingServerConnectionModel()
        @State private var confirmsUnpair = false
        @State private var confirmsRemove = false

        var body: some View {
            VStack(alignment: .leading, spacing: 36) {
                details
                    .task(id: server.id) {
                        async let info: Void = connection.loadInfo(for: server)
                        async let recordings: Void = store.refresh()
                        await store.refreshStatus()
                        _ = await (info, recordings)
                    }
                actions
            }
        }

        private var details: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Paired Server")

                TVSettingsValueRow("Server", value: connection.info?.name ?? server.name)
                if let host = server.endpoint?.baseURL.host() {
                    TVSettingsValueRow("Address", value: host)
                }
                TVSettingsValueRow("Version", value: connection.info?.version ?? "—")
                if !isLocked {
                    TVSettingsValueRow("Free Disk Space", value: RecordingServerSetup.diskSummary(store.status))
                    TVSettingsValueRow("Active Recordings", value: store.status.map { "\($0.activeRecordings)" } ?? "—")
                    TVSettingsValueRow("Status") { reachability }
                }

                if case let .unreachable(error) = store.reachability {
                    Text(error.localizedDescription)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 4)
                }
            }
        }

        @ViewBuilder
        private var reachability: some View {
            switch store.reachability {
            case .reachable:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unreachable:
                Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .unknown:
                Text(verbatim: "—")
            }
        }

        private var actions: some View {
            VStack(alignment: .leading, spacing: 8) {
                if !isLocked, store.reachability.needsRepairing, let baseURL = server.endpoint?.baseURL {
                    actionRow("Pair Again", systemImage: "key") {
                        repair(baseURL)
                    }
                }

                if !isLocked {
                    actionRow("Test Connection", systemImage: "antenna.radiowaves.left.and.right", isBusy: connection.isTesting) {
                        Task { await connection.testConnection(to: server) }
                    }
                    .focused(focus, equals: .testConnection)
                }

                switch connection.testResult {
                case .success:
                    statusText(String(localized: "The recording server is reachable."), color: .green)
                case let .failure(message):
                    statusText(message, color: .red)
                case nil:
                    EmptyView()
                }

                actionRow("Unpair", systemImage: "minus.circle", isDestructive: true, isBusy: connection.isUnpairing) {
                    confirmsUnpair = true
                }
                .confirmationDialog(
                    "Unpair this recording server?",
                    isPresented: $confirmsUnpair,
                    titleVisibility: .visible
                ) {
                    Button("Unpair", role: .destructive) {
                        Task {
                            if await connection.unpair(server) {
                                onRemoved()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }

                actionRow("Remove", systemImage: "trash", isDestructive: true) {
                    confirmsRemove = true
                }
                .confirmationDialog(
                    "Remove this recording server from Lume?",
                    isPresented: $confirmsRemove,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        store.remove(id: server.id)
                        onRemoved()
                    }
                    Button("Cancel", role: .cancel) {}
                }

                if let actionError = connection.actionError {
                    statusText(actionError, color: .red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(RecordingServerSetup.unpairFooter)
                    Text(RecordingServerSetup.disclaimer)
                }
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 8)
            }
        }

        private func actionRow(
            _ title: LocalizedStringKey,
            systemImage: String,
            isDestructive: Bool = false,
            isBusy: Bool = false,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .medium))
                    Text(title)
                    Spacer(minLength: 0)
                    if isBusy { ProgressView() }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle(isDestructive: isDestructive))
        }

        private func statusText(_ message: String, color: Color) -> some View {
            Text(message)
                .font(.system(size: 22))
                .foregroundStyle(color)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }
    }

#endif
