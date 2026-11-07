//
//  TVHuePairingStep.swift
//  Lume
//
//  The tvOS Philips Hue pane's pairing step, shown in place of the pane's top
//  level (see TVHueSettingsPane).
//

#if os(tvOS)

    import SwiftUI

    /// A bridge to pair with: one found on the network, or a typed address
    /// (`bridgeID` nil until the bridge identifies itself).
    struct HuePairingTarget: Hashable {
        var host: String
        var bridgeID: String?
    }

    /// Identifies the bridge, then polls `POST /api` while the user presses its
    /// link button. Nothing here is logged: host, bridge id and keys stay out
    /// of every log line.
    @MainActor
    @Observable
    final class HuePairingModel {
        enum Phase: Equatable {
            case idle
            case identifying
            case identified
            case waitingForLinkButton
        }

        /// The link button stays armed for 30 s; polling stops there.
        static let pollWindow: Duration = .seconds(30)
        static let pollInterval: Duration = .seconds(2)

        var address = ""
        private(set) var phase: Phase = .idle
        private(set) var bridgeName: String?
        private(set) var errorMessage: String?

        @ObservationIgnored private var client: HueBridgeClient?
        @ObservationIgnored private var config: HueBridgeConfig?
        @ObservationIgnored private var host: String?

        var isBusy: Bool {
            phase == .identifying || phase == .waitingForLinkButton
        }

        func addressDidChange() {
            errorMessage = nil
        }

        func identify(_ target: HuePairingTarget) async -> Bool {
            guard let client = HueBridgeClient.pairing(host: target.host, bridgeID: target.bridgeID) else {
                errorMessage = HuePairingStrings.invalidAddress
                return false
            }
            phase = .identifying
            errorMessage = nil
            do {
                let config = try await client.identify()
                self.client = client
                self.config = config
                host = target.host
                bridgeName = config.name
                phase = .identified
                return true
            } catch {
                phase = .idle
                errorMessage = HuePairingStrings.message(for: error)
                return false
            }
        }

        /// Polls until the bridge hands out a key, an error other than "link
        /// button not pressed" comes back, or `pollWindow` runs out. True once
        /// the bridge is stored as this device's only bridge.
        func pair() async -> Bool {
            guard let client, let config, let host else { return false }
            phase = .waitingForLinkButton
            errorMessage = nil
            defer { if phase == .waitingForLinkButton { phase = .identified } }

            let deadline = ContinuousClock.now + Self.pollWindow
            while true {
                do {
                    let credentials = try await client.pair()
                    let secrets = HueBridgeSecrets(credentials: credentials, certificatePin: client.firstUsePin)
                    let saved = HueCredentialStore().savePairing(
                        secrets,
                        for: HueBridgeAddress(id: config.normalizedID, host: host)
                    )
                    guard saved else {
                        errorMessage = HuePairingStrings.saveFailed
                        return false
                    }
                    return true
                } catch .linkButtonNotPressed {
                    guard ContinuousClock.now + Self.pollInterval < deadline else {
                        errorMessage = HuePairingStrings.linkButtonTimedOut
                        return false
                    }
                    do {
                        try await Task.sleep(for: Self.pollInterval)
                    } catch {
                        return false
                    }
                } catch .cancelled {
                    return false
                } catch {
                    errorMessage = HuePairingStrings.message(for: error)
                    return false
                }
            }
        }
    }

    struct TVHuePairingStep: View {
        let target: HuePairingTarget?
        let onPaired: () -> Void
        let onCancel: () -> Void

        @State private var model = HuePairingModel()
        @State private var pairing: Task<Void, Never>?
        @FocusState private var focus: Field?

        private enum Field: Hashable {
            case address
            case pair
            case cancel
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("settings.hue.pairing.title")

                if target == nil, model.bridgeName == nil {
                    addressInput
                }

                if let bridgeName = model.bridgeName {
                    TVSettingsValueRow("settings.hue.bridge", value: bridgeName)
                    linkButtonStep
                } else if model.phase == .identifying {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text(String(localized: "settings.hue.pairing.connecting", defaultValue: "Connecting…"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                if let errorMessage = model.errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Button("settings.hue.pairing.cancel", action: cancel)
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .focused($focus, equals: .cancel)
                    .padding(.top, 8)
            }
            .task {
                if let target {
                    Task { @MainActor in focus = .cancel }
                    if await model.identify(target) {
                        Task { @MainActor in focus = .pair }
                    }
                } else {
                    Task { @MainActor in focus = .address }
                }
            }
            .onDisappear { pairing?.cancel() }
        }

        private var addressInput: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsField(
                    title: "settings.hue.address.title",
                    placeholder: "settings.hue.address.placeholder",
                    text: $model.address,
                    contentType: .URL
                )
                .keyboardType(.numbersAndPunctuation)
                .focused($focus, equals: .address)
                .onSubmit { connectToAddress() }
                .onChange(of: model.address) { model.addressDidChange() }

                Text(String(
                    localized: "settings.hue.address.footer",
                    defaultValue: "The bridge's IP address, shown in the Hue app under Settings › Bridges."
                ))
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                TVSettingsActionRow(
                    "settings.hue.address.connect",
                    systemImage: "network",
                    isBusy: model.phase == .identifying,
                    action: connectToAddress
                )
                .disabled(trimmedAddress.isEmpty || model.phase == .identifying)
            }
        }

        private var linkButtonStep: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(
                    localized: "settings.hue.pairing.instructions",
                    defaultValue: "Press the round link button on top of the Hue Bridge, then select Pair within 30 seconds."
                ))
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button(action: startPairing) {
                    HStack(spacing: 16) {
                        Image(systemName: "link")
                            .font(.system(size: 22, weight: .medium))
                        Text(pairTitle)
                        Spacer(minLength: 0)
                        if model.phase == .waitingForLinkButton { ProgressView() }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .focused($focus, equals: .pair)
            }
        }

        private var pairTitle: String {
            if model.phase == .waitingForLinkButton {
                String(localized: "settings.hue.pairing.waiting", defaultValue: "Waiting for the Link Button…")
            } else if model.errorMessage != nil {
                String(localized: "settings.hue.pairing.retry", defaultValue: "Try Again")
            } else {
                String(localized: "settings.hue.pairing.pair", defaultValue: "Pair")
            }
        }

        private var trimmedAddress: String {
            model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func connectToAddress() {
            let host = trimmedAddress
            guard !host.isEmpty, model.phase != .identifying else { return }
            Task {
                if await model.identify(HuePairingTarget(host: host, bridgeID: nil)) {
                    Task { @MainActor in
                        // Submitting from the keyboard hands focus back to the
                        // field as it dismisses, after a write made right away.
                        try? await Task.sleep(for: .milliseconds(500))
                        focus = .pair
                    }
                }
            }
        }

        private func startPairing() {
            guard !model.isBusy else { return }
            pairing = Task {
                if await model.pair() {
                    onPaired()
                }
            }
        }

        private func cancel() {
            pairing?.cancel()
            onCancel()
        }
    }

    /// Messages for the pairing step. Never interpolates a host, id or key.
    enum HuePairingStrings {
        static var invalidAddress: String {
            String(localized: "settings.hue.error.invalidAddress", defaultValue: "Enter the bridge's IP address, like 192.168.1.20.")
        }

        static var linkButtonTimedOut: String {
            String(
                localized: "settings.hue.error.linkButton",
                defaultValue: "The link button wasn't pressed in time. Press it, then try again."
            )
        }

        static var saveFailed: String {
            String(localized: "settings.hue.error.saveFailed", defaultValue: "Lume couldn't store the bridge's key on this Apple TV.")
        }

        static func message(for error: HueBridgeError) -> String {
            switch error {
            case .linkButtonNotPressed:
                linkButtonTimedOut
            case .untrustedCertificate, .wrongBridge:
                String(
                    localized: "settings.hue.error.untrusted",
                    defaultValue: "This address didn't answer as a genuine Hue Bridge."
                )
            case .unauthorized:
                String(
                    localized: "settings.hue.error.unauthorized",
                    defaultValue: "The bridge no longer knows this Apple TV. Forget the bridge and pair it again."
                )
            case .rateLimited:
                String(localized: "settings.hue.error.rateLimited", defaultValue: "The bridge is busy. Wait a moment, then try again.")
            case .transport, .server, .notFound, .invalidResponse:
                String(
                    localized: "settings.hue.error.unreachable",
                    defaultValue: "Couldn't reach a Hue Bridge at this address. Check that it's on the same network."
                )
            case .invalidRequest:
                invalidAddress
            case .areaInUse, .pairingFailed, .rejected, .cancelled:
                String(localized: "settings.hue.error.generic", defaultValue: "The bridge turned the request down. Try again.")
            }
        }
    }

#endif
