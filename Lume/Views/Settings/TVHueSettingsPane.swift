//
//  TVHueSettingsPane.swift
//  Lume
//
//  Settings › Player › Philips Hue on tvOS: pair one Hue Bridge (found over
//  Bonjour or typed), pick its entertainment area, and turn light sync on.
//  Everything is device-local and applies to every profile.
//

#if os(tvOS)

    import SwiftUI

    struct TVHueSettingsPane: View {
        /// SettingsView's paywall, so the pane never stacks a second one.
        let presentPaywall: (PremiumFeature) -> Void

        @AppStorage(PlayerSettings.Hue.enabledKey) private var isEnabled = PlayerSettings.Hue.enabledDefault
        @AppStorage(PlayerSettings.Hue.intensityKey) private var intensityRaw = PlayerSettings.Hue.intensityDefault.rawValue
        @AppStorage(PlayerSettings.Hue.entertainmentAreaKey) private var areaID = ""

        @State private var premium = PremiumManager.shared
        @State private var discovery = HueBridgeDiscovery()
        /// Read on appear, not as an initial value, which every re-creation
        /// of the pane would evaluate against the keychain.
        @State private var pairedBridge: HueBridgeAddress?
        @State private var route: Route?
        @State private var areas: [HueEntertainmentConfiguration] = []
        @State private var isLoadingAreas = false
        @State private var areaError: String?
        @State private var showsSensitivityNotice = false
        /// What the sensitivity notice unlocks once confirmed.
        @State private var noticeConfirms: NoticeAction = .enable
        @State private var lightTest: Task<Void, Never>?
        @State private var lightTestFailure: String?
        @State private var confirmsForget = false
        @FocusState private var focus: Row?

        private enum Route: Hashable {
            case manualAddress
            /// `row` is the discovered bridge's row, focused again on cancel.
            case bridge(HuePairingTarget, row: String)

            var opener: Row {
                switch self {
                case .manualAddress: .manualAddress
                case let .bridge(_, row): .bridge(row)
                }
            }

            var target: HuePairingTarget? {
                if case let .bridge(target, _) = self { target } else { nil }
            }
        }

        private enum Row: Hashable {
            case sync, intensity, bridge(String), manualAddress, forget, area(String), reloadAreas, testLights
        }

        private enum NoticeAction {
            case enable, testLights
        }

        private var shouldBrowse: Bool {
            premium.isPremium && pairedBridge == nil && route == nil
        }

        /// Read through `intensityRaw` so the pane re-renders when it changes.
        private var intensity: HueIntensity {
            _ = intensityRaw
            return PlayerSettings.Hue.intensity()
        }

        var body: some View {
            Group {
                if let route {
                    TVHuePairingStep(target: route.target, onPaired: pairingFinished, onCancel: cancelPairing)
                        .onExitCommand(perform: cancelPairing)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        syncSection
                        bridgeSection
                        if pairedBridge != nil, premium.isPremium {
                            areaSection
                        }
                    }
                    .defaultFocus($focus, .sync, priority: .userInitiated)
                }
            }
            .onAppear {
                pairedBridge = HueCredentialStore().pairedBridge
                updateDiscovery()
            }
            .onDisappear {
                discovery.stop()
                lightTest?.cancel()
            }
            .onChange(of: shouldBrowse) { updateDiscovery() }
            .task(id: premium.isPremium ? pairedBridge : nil) { await loadAreas() }
            .hueSensitivityNotice(isPresented: $showsSensitivityNotice) {
                switch noticeConfirms {
                case .enable: isEnabled = true
                case .testLights: runLightTest()
                }
            }
            .alert(Text("settings.hue.forget.confirmTitle"), isPresented: $confirmsForget) {
                Button("settings.hue.forget.confirm", role: .destructive, action: forgetBridge)
                Button("settings.hue.notice.cancel", role: .cancel) {}
            } message: {
                Text("settings.hue.forget.confirmMessage")
            }
        }

        // MARK: - Sync

        private var syncSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("settings.hue.section.sync")

                TVOptionToggleRow(
                    title: "settings.hue.sync",
                    isOn: Binding(get: { premium.isPremium && isEnabled }, set: setEnabled),
                    showsPremiumBadge: !premium.isPremium
                )
                .focused($focus, equals: .sync)

                TVOptionCycleRow(
                    title: "settings.hue.intensity",
                    valueLabel: intensity.settingsTitle,
                    showsPremiumBadge: !premium.isPremium
                ) {
                    guard premium.isPremium else { return presentPaywall(.hueSync) }
                    let levels = HueIntensity.allCases.filter { $0 != .off }
                    let index = levels.firstIndex(of: intensity) ?? 0
                    intensityRaw = levels[(index + 1) % levels.count].rawValue
                }
                .focused($focus, equals: .intensity)

                footnote(String(
                    localized: "settings.hue.sync.footer",
                    // swiftlint:disable:next line_length
                    defaultValue: "The lights of a Hue entertainment area follow the colours at the edges of the picture while video plays. Choose Off or another level from the player's menu at any time."
                ))
                .padding(.top, 6)
            }
        }

        private func footnote(_ text: String) -> some View {
            Text(verbatim: text)
                .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }

        private func setEnabled(_ newValue: Bool) {
            guard premium.isPremium else { return presentPaywall(.hueSync) }
            if newValue, !PlayerSettings.Hue.lightSensitivityNoticeShown() {
                noticeConfirms = .enable
                showsSensitivityNotice = true
            } else {
                isEnabled = newValue
            }
        }

        // MARK: - Bridge

        private var bridgeSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("settings.hue.section.bridge")

                if let pairedBridge {
                    TVSettingsValueRow("settings.hue.bridge", value: pairedBridge.host)
                    TVSettingsActionRow("settings.hue.forget", systemImage: "minus.circle", isDestructive: true) {
                        confirmsForget = true
                    }
                    .focused($focus, equals: .forget)
                } else {
                    if premium.isPremium {
                        ForEach(discovery.bridges) { bridge in
                            discoveredBridgeRow(bridge)
                        }
                    }
                    Button {
                        open(.manualAddress)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 22, weight: .medium))
                            Text("settings.hue.address.enter")
                            if !premium.isPremium {
                                PremiumBadge()
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .focused($focus, equals: .manualAddress)

                    if premium.isPremium, let status = discoveryStatus {
                        footnote(status)
                            .padding(.top, 6)
                    }
                }
            }
        }

        private func discoveredBridgeRow(_ bridge: DiscoveredHueBridge) -> some View {
            Button {
                guard let host = bridge.host else { return }
                open(.bridge(HuePairingTarget(host: host, bridgeID: bridge.bridgeID), row: bridge.id))
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "light.recessed")
                        .font(.system(size: 22, weight: .medium))
                    Text(verbatim: bridge.name)
                    Spacer(minLength: 0)
                    if bridge.host == nil { ProgressView() }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .disabled(bridge.host == nil)
            .focused($focus, equals: .bridge(bridge.id))
        }

        private var discoveryStatus: String? {
            switch discovery.state {
            case .browsing:
                discovery.bridges.isEmpty
                    ? String(localized: "settings.hue.discovery.searching", defaultValue: "Looking for Hue Bridges on this network…")
                    : nil
            case .waitingForLocalNetwork:
                String(
                    localized: "settings.hue.discovery.localNetwork",
                    defaultValue: "Lume needs Local Network access to find the bridge. Allow it in Settings › Apps › Lume, or enter the bridge's IP address."
                )
            case .unavailable:
                String(
                    localized: "settings.hue.discovery.unavailable",
                    defaultValue: "Couldn't search this network. Enter the bridge's IP address instead."
                )
            case .idle:
                nil
            }
        }

        private func open(_ route: Route) {
            guard premium.isPremium else { return presentPaywall(.hueSync) }
            self.route = route
        }

        private func pairingFinished() {
            route = nil
            pairedBridge = HueCredentialStore().pairedBridge
            Task { @MainActor in focus = .sync }
        }

        private func cancelPairing() {
            guard let route else { return }
            self.route = nil
            Task { @MainActor in focus = route.opener }
        }

        private func forgetBridge() {
            HueCredentialStore().forget()
            pairedBridge = nil
            areas = []
            areaError = nil
            Task { @MainActor in focus = .manualAddress }
        }

        private func updateDiscovery() {
            if shouldBrowse {
                discovery.start()
            } else {
                discovery.stop()
            }
        }

        // MARK: - Entertainment area

        private var areaSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("settings.hue.section.area")

                ForEach(areas) { area in
                    areaRow(area)
                }

                if isLoadingAreas, areas.isEmpty {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text(String(localized: "settings.hue.area.loading", defaultValue: "Loading entertainment areas…"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                } else if let areaError {
                    Text(verbatim: areaError)
                        .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    TVSettingsActionRow("settings.hue.area.reload", systemImage: "arrow.clockwise") {
                        Task { await loadAreas() }
                    }
                    .focused($focus, equals: .reloadAreas)
                } else if !isLoadingAreas, areas.isEmpty {
                    footnote(String(
                        localized: "settings.hue.area.empty",
                        defaultValue: "This bridge has no entertainment areas. Create one in the Hue app under Settings › Entertainment areas."
                    ))
                }

                if areas.contains(where: { $0.id == areaID }) {
                    testLightsRow
                }
            }
        }

        // MARK: - Test lights

        @ViewBuilder private var testLightsRow: some View {
            TVSettingsActionRow("settings.hue.test", systemImage: "lightbulb.max", isBusy: lightTest != nil) {
                guard lightTest == nil else { return }
                if PlayerSettings.Hue.lightSensitivityNoticeShown() {
                    runLightTest()
                } else {
                    noticeConfirms = .testLights
                    showsSensitivityNotice = true
                }
            }
            .focused($focus, equals: .testLights)

            if let lightTestFailure {
                Text(verbatim: lightTestFailure)
                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                    .foregroundStyle(.red)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            } else {
                footnote(String(
                    localized: "settings.hue.test.footer",
                    defaultValue: "The area's lights turn red, green, blue and white, then go back to how they were."
                ))
            }
        }

        /// Streams the test pattern through the same session playback uses,
        /// then ends it, which restores the lights.
        private func runLightTest() {
            guard premium.isPremium else { return presentPaywall(.hueSync) }
            guard lightTest == nil else { return }
            lightTestFailure = nil
            let controller = HueSyncController.shared
            let pattern = HueTestPatternSource()
            lightTest = Task {
                await controller.start(source: pattern, intensity: .intense, reduceMotion: false).value
                var waited = 0
                while controller.state == .connecting, waited < 50, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                if controller.state == .streaming {
                    try? await Task.sleep(for: HueTestPattern.duration)
                }
                let failure = Self.lightTestFailure(for: controller.state)
                await controller.stop().value
                withExtendedLifetime(pattern) {}
                lightTestFailure = failure
                lightTest = nil
            }
        }

        private static func lightTestFailure(for state: HueSyncState) -> String? {
            switch state {
            case .streaming, .idle, .unavailable:
                nil
            case .connecting, .error(.stream):
                String(
                    localized: "settings.hue.test.streamFailed",
                    defaultValue: "The bridge didn't accept the light stream. Check that the Apple TV and the bridge are on the same network."
                )
            case .areaInUse:
                String(
                    localized: "settings.hue.test.areaInUse",
                    defaultValue: "Another app is using this entertainment area. Stop it there, then try again."
                )
            case .error(.unsupportedArea):
                String(
                    localized: "settings.hue.test.unsupportedArea",
                    defaultValue: "This entertainment area has no lights Lume can control."
                )
            case let .error(.bridge(error)):
                HuePairingStrings.message(for: error)
            }
        }

        private func areaRow(_ area: HueEntertainmentConfiguration) -> some View {
            Button {
                areaID = area.id
            } label: {
                HStack(spacing: 16) {
                    TVSwitchRowCheckmark()
                        .opacity(area.id == areaID ? 1 : 0)
                    Text(verbatim: area.name)
                    Spacer(minLength: 0)
                    Text(String(localized: "settings.hue.area.channels", defaultValue: "Channels: \(area.channels.count)"))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .modifier(TVSwitchRowActiveState(isActive: area.id == areaID))
            .focused($focus, equals: .area(area.id))
        }

        private func loadAreas() async {
            guard premium.isPremium, let pairedBridge, let secrets = HueCredentialStore().loadSecrets(),
                  let client = HueBridgeClient(bridge: pairedBridge, secrets: secrets)
            else {
                areas = []
                return
            }
            isLoadingAreas = true
            areaError = nil
            defer { isLoadingAreas = false }
            do {
                let loaded = try await client.entertainmentConfigurations()
                areas = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch .cancelled {
                return
            } catch {
                areaError = HuePairingStrings.message(for: error)
            }
        }
    }

#endif
