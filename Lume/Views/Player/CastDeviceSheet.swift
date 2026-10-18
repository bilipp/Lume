//
//  CastDeviceSheet.swift
//  Lume
//
//  The full-screen player's Cast picker on iPhone and iPad: the Chromecast
//  receivers discovery finds, the one Lume is connected to, and an AirPlay
//  row that opens the system route picker.
//
//  Discovery runs only while the sheet is open, so the local-network prompt
//  comes with the first tap on the Cast button and never at launch.
//
//  Chromecast is Lume Pro; AirPlay is free. A free user's receiver rows open
//  the paywall instead of connecting, and the AirPlay row always works. When
//  the stream on screen can't be cast, the receiver rows are disabled and the
//  resolver's reason says why.
//

#if os(iOS)
    import SwiftUI

    struct CastDeviceSheet: View {
        let castSession: PlayerCastSession

        @Environment(\.dismiss) private var dismiss
        @State private var cast = CastService.shared
        @State private var premium = PremiumManager.shared
        @State private var showsPaywall = false
        @State private var searchTimedOut = false

        var body: some View {
            NavigationStack {
                List {
                    chromecastSection
                    airPlaySection
                }
                .navigationTitle(Text(Strings.title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .paywall(isPresented: $showsPaywall, highlight: .chromecast)
            .onAppear { cast.startDiscovery() }
            .onDisappear { cast.stopDiscovery() }
            .task {
                try? await Task.sleep(for: .seconds(Self.searchPatience))
                searchTimedOut = true
            }
            .onChange(of: cast.chromecastConnection) { _, connection in
                // The player takes it from here and swaps its controls for
                // the casting surface.
                if connection == .connected, cast.isPlayerCastRequested {
                    dismiss()
                }
            }
        }

        /// How long "Searching" shows before an empty list reads as "none".
        private static let searchPatience: Double = 6

        private var unsupportedReason: CastStreamResolver.Reason? {
            castSession.castability.unsupportedReason
        }

        private var canPickReceiver: Bool {
            unsupportedReason == nil
        }

        // MARK: - Chromecast

        private var chromecastSection: some View {
            Section {
                switch cast.chromecastConnection {
                case .connected:
                    connectedRow
                case .connecting:
                    connectingRow
                case .idle:
                    EmptyView()
                }
                ForEach(availableDevices) { device in
                    deviceRow(device)
                }
                if availableDevices.isEmpty, cast.chromecastConnection == .idle {
                    searchStatus
                }
            } header: {
                Text(Strings.chromecastHeader)
            } footer: {
                if let unsupportedReason {
                    Text(unsupportedReason.message)
                }
            }
        }

        /// Discovered receivers, less the one already in the section's top row.
        private var availableDevices: [CastDevice] {
            guard cast.chromecastConnection != .idle, let name = cast.chromecastDeviceName else {
                return cast.devices
            }
            return cast.devices.filter { $0.name != name }
        }

        private func deviceRow(_ device: CastDevice) -> some View {
            receiverRow(name: device.name, detail: device.modelName, systemImage: device.kind.systemImage) {
                cast.connect(to: device)
            }
            .disabled(!canPickReceiver || cast.chromecastConnection == .connecting)
        }

        /// The receiver Lume is connected to. Picking it casts this player's
        /// stream there without a new connection — it may be playing
        /// something else, or a session the SDK resumed at launch.
        @ViewBuilder
        private var connectedRow: some View {
            receiverRow(
                name: cast.chromecastDeviceName ?? String(localized: CastDevice.unnamedName),
                detail: String(localized: "Connected"),
                systemImage: "tv.badge.wifi.fill"
            ) {
                cast.requestPlayerCast()
                dismiss()
            }
            .disabled(!canPickReceiver)

            Button("Disconnect", role: .destructive) {
                cast.endSession(stopReceiver: true)
            }
        }

        /// A Chromecast row: Pro runs `action`, everyone else gets the paywall.
        private func receiverRow(
            name: String,
            detail: String?,
            systemImage: String,
            action: @escaping () -> Void
        ) -> some View {
            Button {
                if premium.isPremium {
                    action()
                } else {
                    showsPaywall = true
                }
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                            if let detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: systemImage)
                    }
                    Spacer()
                    if !premium.isPremium {
                        PremiumBadge()
                    }
                }
            }
        }

        private var connectingRow: some View {
            HStack {
                Label {
                    Text(Self.connectingTitle(
                        deviceName: cast.chromecastDeviceName ?? String(localized: CastDevice.unnamedName)
                    ))
                } icon: {
                    ProgressView()
                }
                Spacer()
                Button("Cancel") {
                    cast.endSession(stopReceiver: true)
                }
                .buttonStyle(.borderless)
            }
        }

        static func connectingTitle(deviceName name: String) -> LocalizedStringResource {
            LocalizedStringResource(
                "player.cast.sheet.connecting",
                defaultValue: "Connecting to \(name)…",
                comment: "Player › Cast sheet: row shown while Lume connects to a Chromecast. The argument is the Chromecast's name."
            )
        }

        @ViewBuilder
        private var searchStatus: some View {
            if searchTimedOut {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings.noDevices)
                        .foregroundStyle(.secondary)
                    Text(Strings.localNetworkHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(Strings.searching)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // MARK: - AirPlay

        private var airPlaySection: some View {
            Section {
                ZStack {
                    Label {
                        Text(Strings.airPlayRow)
                    } icon: {
                        Image(systemName: "airplayvideo")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                    AirPlayRoutePicker(rowLabel: String(localized: Strings.airPlayRow))
                }
            } header: {
                Text("AirPlay")
            }
        }
    }

    private enum Strings {
        static let title = LocalizedStringResource(
            "player.cast.sheet.title",
            defaultValue: "Cast To",
            comment: "Player › Cast sheet: title of the sheet that lists Chromecast and AirPlay devices to play on."
        )
        static let chromecastHeader = LocalizedStringResource(
            "player.cast.sheet.chromecast",
            defaultValue: "Chromecast",
            comment: "Player › Cast sheet: header above the list of Chromecast devices."
        )
        static let searching = LocalizedStringResource(
            "player.cast.sheet.searching",
            defaultValue: "Searching for devices…",
            comment: "Player › Cast sheet: shown while Lume looks for Chromecast devices on the network."
        )
        static let noDevices = LocalizedStringResource(
            "player.cast.sheet.no-devices",
            defaultValue: "No devices found",
            comment: "Player › Cast sheet: shown when no Chromecast device was found on the network."
        )
        static let localNetworkHint = LocalizedStringResource(
            "player.cast.sheet.local-network-hint",
            defaultValue: """
            Make sure your Chromecast is on the same Wi-Fi network as this device. \
            If you declined Local Network access for Lume, allow it again in Settings › Privacy & Security › Local Network.
            """,
            comment: "Player › Cast sheet: hint below “No devices found” on how to make a Chromecast show up."
        )
        static let airPlayRow = LocalizedStringResource(
            "player.cast.sheet.airplay",
            defaultValue: "AirPlay…",
            comment: "Player › Cast sheet: row that opens the system AirPlay device picker."
        )
    }
#endif
