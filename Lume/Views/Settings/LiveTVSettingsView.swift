//
//  LiveTVSettingsView.swift
//  Lume
//
//  The iOS / macOS / visionOS Live TV page behind the root Live TV row: how
//  the Live TV tab lays out channels (Guide or List — the only place to switch
//  it), and the recording server with its recordings library. tvOS builds its
//  own pane in TVLiveTVSettingsPane.
//

#if !os(tvOS)

    import SwiftUI

    struct LiveTVSettingsView: View {
        @AppStorage(LiveTVLayoutMode.storageKey)
        private var layoutModeRaw = LiveTVLayoutMode.defaultMode.rawValue
        @State private var configService = RecordingServerConfigService.shared
        @State private var store = RecordingServerStore.shared
        @State private var showPaywall = false
        @State private var showingRecordings = false

        /// Resolved through `LiveTVLayoutMode(storedValue:)`, so a missing or
        /// unknown stored value reads as the platform default rather than
        /// leaving the picker without a selection.
        private var layoutMode: Binding<LiveTVLayoutMode> {
            Binding(
                get: { LiveTVLayoutMode(storedValue: layoutModeRaw) },
                set: { layoutModeRaw = $0.rawValue }
            )
        }

        private var access: RecordingSettingsAccess {
            RecordingSettingsAccess(
                isUnlocked: store.isUnlocked,
                hasServers: !configService.servers.isEmpty,
                isPaired: store.isPaired
            )
        }

        var body: some View {
            List {
                Section {
                    Picker("Live TV Layout", selection: layoutMode) {
                        ForEach(LiveTVLayoutMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("How the Live TV tab shows channels: Guide lays them out on a programme timeline, List as a plain channel list.")
                }

                Section {
                    recordingServerRow
                    if access.showsRecordingsRow {
                        recordingsRow
                    }
                } header: {
                    Text("Recordings")
                } footer: {
                    Text(RecordingServerSetup.intro)
                }
            }
            .platformNavigationTitle("Live TV")
            .recordingsLibrarySheet(isPresented: $showingRecordings)
            .paywall(isPresented: $showPaywall, highlight: .recordingServer)
        }

        // MARK: - Recording

        /// Free with nothing paired, the row opens the paywall rather than a
        /// page that would only repeat it. A lapsed subscriber's paired server
        /// stays reachable, crown and all, so it can be unpaired or removed.
        @ViewBuilder
        private var recordingServerRow: some View {
            if access.serverRowOpensPaywall {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 8) {
                        recordingServerLabel
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    RecordingServerSettingsView()
                } label: {
                    recordingServerLabel
                }
            }
        }

        private var recordingServerLabel: some View {
            HStack {
                Label("Recording Server", systemImage: "record.circle")
                if access.serverRowShowsBadge {
                    PremiumBadge()
                }
                Spacer(minLength: 8)
                if let value = recordingServerValue {
                    value
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }

        /// The paired server's name, "Not paired" once pairing is open to the
        /// user, and nothing on the locked row (the crown says enough).
        private var recordingServerValue: Text? {
            if let server = configService.activeServer, !server.name.isEmpty {
                return Text(verbatim: server.name)
            }
            return access.serverRowOpensPaywall ? nil : Text("Not paired")
        }

        /// The same rule as the Live TV toolbar's Recordings button: without
        /// Lume Pro it carries the plain crown and opens the paywall.
        private var recordingsRow: some View {
            Button {
                if access.recordingsRowOpensPaywall {
                    showPaywall = true
                } else {
                    showingRecordings = true
                }
            } label: {
                HStack(spacing: 8) {
                    Label("Recordings", systemImage: access.recordingsRowOpensPaywall ? "crown" : "recordingtape")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

#endif
