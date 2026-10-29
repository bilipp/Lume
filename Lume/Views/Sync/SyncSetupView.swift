//
//  SyncSetupView.swift
//  Lume
//
//  The first-run sync choice on a fresh install: iCloud (the default), Lume
//  Cloud or Don't Sync, before the add-playlist form or the launch wait. Lume
//  Cloud opens a second step to create an account, join one with a code or a
//  recovery key, or, when the user's other Apple devices already use Lume
//  Cloud, join that account without a code. The account flows are the
//  Settings ▸ Sync sheets. tvOS lays the same steps out as rows
//  (TVSyncSetupView).
//

import SwiftUI

struct SyncSetupView: View {
    let coordinator: CloudSyncCoordinator

    @State private var model = SyncSetupModel(selection: LumeCloudSettings.defaultBackend)

    var body: some View {
        Group {
            #if os(tvOS)
                TVSyncSetupView(coordinator: coordinator, model: model)
            #else
                SyncSetupStack(coordinator: coordinator, model: model)
            #endif
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: $model.isAlertPresented,
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(verbatim: alert.message)
        }
        // A flow left early (Menu during a restore on tvOS) can still finish
        // the switch behind the step.
        .onChange(of: coordinator.selectedBackend) { model.backendDidChange(using: coordinator) }
    }
}

/// The text and icon of each first-run option, shared with tvOS.
enum SyncSetupText {
    static let title: LocalizedStringKey = "Sync Your Library"
    static let subtitle: LocalizedStringKey = "Keep your profiles, playlists and viewing progress in step across your devices."
    static let footnote: LocalizedStringKey = "You can change this anytime in Settings ▸ Sync."
    static let recommended: LocalizedStringKey = "Recommended"
    static let lumeCloudSubtitle: LocalizedStringKey = "End-to-end encrypted. Only your devices can read what you sync."

    static func name(of backend: SyncBackendSelection) -> LocalizedStringKey {
        backend == .off ? "Don’t Sync" : SyncSettingsPromptText.name(of: backend)
    }

    static func detail(of backend: SyncBackendSelection) -> LocalizedStringKey {
        switch backend {
        case .icloud: "Syncs through your Apple Account."
        case .lumecloud: "End-to-end encrypted. Syncs across Apple and Android devices."
        case .off: "Everything stays on this device."
        }
    }

    static func systemImage(of backend: SyncBackendSelection) -> String {
        switch backend {
        case .icloud: "icloud.fill"
        case .lumecloud: "lock.icloud.fill"
        case .off: "icloud.slash"
        }
    }

    /// The Lume Cloud step's options, in order.
    enum LumeCloudOption: Hashable, CaseIterable {
        /// The account the user's other Apple devices sync with.
        case existing
        case create
        case join
        case restore

        var title: LocalizedStringKey {
            switch self {
            case .existing: "Use Your Existing Account"
            case .create: "Create New Account"
            case .join: "Join with a Code"
            case .restore: "Restore from Recovery Key"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .existing: "Your other Apple devices already sync with Lume Cloud. No code needed."
            case .create: "Start fresh. You’ll get a recovery key to keep safe."
            case .join: "Pair with a device that already uses Lume Cloud."
            case .restore: "Use the key you saved when you created your account."
            }
        }

        var systemImage: String {
            switch self {
            case .existing: "checkmark.icloud.fill"
            case .create: "plus.circle.fill"
            case .join: "qrcode"
            case .restore: "key.fill"
            }
        }

        /// What the option does: an account call, or a flow it opens.
        @MainActor
        func perform(with model: SyncSetupModel, coordinator: CloudSyncCoordinator) {
            switch self {
            case .existing: model.joinOfferedAccount(using: coordinator)
            case .create: model.createAccount(using: coordinator)
            case .join: model.flow = .join
            case .restore: model.flow = .restore
            }
        }

        /// The options to offer: `existing` only once the Apple-wide record
        /// named an account.
        static func available(hasOfferedAccount: Bool) -> [LumeCloudOption] {
            hasOfferedAccount ? allCases : allCases.filter { $0 != .existing }
        }
    }
}

#if !os(tvOS)

    /// The two steps in a navigation stack, with the account flows as sheets.
    private struct SyncSetupStack: View {
        let coordinator: CloudSyncCoordinator
        @Bindable var model: SyncSetupModel

        var body: some View {
            NavigationStack {
                SyncSetupChoiceStep(coordinator: coordinator, model: model)
                    .navigationDestination(isPresented: $model.showsLumeCloud) {
                        SyncSetupLumeCloudStep(coordinator: coordinator, model: model)
                    }
            }
            .sheet(item: $model.flow, onDismiss: flowDidClose, content: flowSheet)
        }

        private func flowDidClose() {
            model.flowDidClose(using: coordinator)
        }

        @ViewBuilder
        private func flowSheet(for flow: SyncSetupModel.Flow) -> some View {
            switch flow {
            case .join: LumeCloudPairingSheet(role: .join)
            case .restore: LumeCloudRestoreSheet()
            case let .recoveryKey(recoveryKey): LumeCloudRecoveryKeyView(context: .created(recoveryKey: recoveryKey))
            }
        }
    }

    // MARK: - Choice

    private struct SyncSetupChoiceStep: View {
        let coordinator: CloudSyncCoordinator
        @Bindable var model: SyncSetupModel

        var body: some View {
            SyncSetupPage {
                SyncSetupHeader(
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill",
                    title: SyncSetupText.title,
                    subtitle: SyncSetupText.subtitle
                )
                VStack(spacing: 12) {
                    ForEach(coordinator.availableBackends, id: \.self) { backend in
                        SyncSetupOptionCard(
                            title: SyncSetupText.name(of: backend),
                            detail: SyncSetupText.detail(of: backend),
                            systemImage: SyncSetupText.systemImage(of: backend),
                            badge: backend == .icloud ? SyncSetupText.recommended : nil,
                            accessory: .selection(model.selection == backend)
                        ) {
                            model.selection = backend
                        }
                    }
                }
                .disabled(model.isWorking)
            } bottomBar: {
                VStack(spacing: 14) {
                    Text(SyncSetupText.footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        model.commit(using: coordinator)
                    } label: {
                        ZStack {
                            Text("Continue")
                                .opacity(model.isWorking ? 0 : 1)
                            if model.isWorking {
                                ProgressView()
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWorking)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .syncSetupHidesNavigationBar()
        }
    }

    // MARK: - Lume Cloud

    private struct SyncSetupLumeCloudStep: View {
        let coordinator: CloudSyncCoordinator
        let model: SyncSetupModel

        var body: some View {
            SyncSetupPage {
                SyncSetupHeader(
                    systemImage: SyncSetupText.systemImage(of: .lumecloud),
                    title: SyncSettingsPromptText.name(of: .lumecloud),
                    subtitle: SyncSetupText.lumeCloudSubtitle
                )
                VStack(spacing: 12) {
                    ForEach(SyncSetupText.LumeCloudOption.available(hasOfferedAccount: coordinator.offeredLumeCloudAccount != nil), id: \.self) { option in
                        SyncSetupOptionCard(
                            title: option.title,
                            detail: option.detail,
                            systemImage: option.systemImage,
                            accessory: .chevron
                        ) {
                            option.perform(with: model, coordinator: coordinator)
                        }
                    }
                }
                .disabled(model.isWorking)
                if model.isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Working…")
                            .foregroundStyle(.secondary)
                    }
                }
            } bottomBar: {
                EmptyView()
            }
            .navigationBarBackButtonHidden(model.isWorking)
        }
    }

    // MARK: - Building blocks

    /// A centred, width-capped scrolling page with a pinned bottom bar.
    private struct SyncSetupPage<Content: View, BottomBar: View>: View {
        @ViewBuilder let content: Content
        @ViewBuilder let bottomBar: BottomBar

        private static var maxWidth: CGFloat {
            520
        }

        var body: some View {
            ScrollView {
                VStack(spacing: 28) {
                    content
                }
                .frame(maxWidth: Self.maxWidth)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                bottomBar
                    .frame(maxWidth: Self.maxWidth)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private struct SyncSetupHeader: View {
        let systemImage: String
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 16)
        }
    }

    /// One tappable option: a radio card on the choice step, a card that opens
    /// its flow on the Lume Cloud step.
    private struct SyncSetupOptionCard: View {
        enum Accessory {
            case selection(Bool)
            case chevron
        }

        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let systemImage: String
        var badge: LocalizedStringKey?
        let accessory: Accessory
        let action: () -> Void

        private var isSelected: Bool {
            if case .selection(true) = accessory { return true }
            return false
        }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.headline)
                            if let badge {
                                Text(badge)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.tint.opacity(0.15), in: Capsule())
                            }
                        }
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    accessoryImage
                }
                .foregroundStyle(.primary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: shape)
                .overlay {
                    shape.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .syncSetupCardHoverEffect()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        @ViewBuilder
        private var accessoryImage: some View {
            switch accessory {
            case let .selection(selected):
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            case .chevron:
                Image(systemName: "chevron.forward")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    private extension View {
        /// The choice step is the stack's root and needs no bar; macOS has none to hide.
        func syncSetupHidesNavigationBar() -> some View {
            #if os(macOS)
                self
            #else
                toolbar(.hidden, for: .navigationBar)
            #endif
        }

        /// visionOS lifts the card under the user's gaze.
        func syncSetupCardHoverEffect() -> some View {
            #if os(visionOS)
                hoverEffect(.highlight)
            #else
                self
            #endif
        }
    }

#endif
