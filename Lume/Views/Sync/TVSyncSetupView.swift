//
//  TVSyncSetupView.swift
//  Lume
//
//  The first-run sync choice on tvOS (see SyncSetupView): full-width rows,
//  where Select commits at once. Focus starts on the preselected backend.
//  Lume Cloud swaps in its step in place, focus on its first row; an account
//  flow then swaps in the Settings ▸ Sync step it shares
//  (TVLumeCloudRouteDetail). Menu backs out one level, onto the row that
//  opened it, and is left to the system on the choice itself.
//

#if os(tvOS)

    import SwiftUI

    struct TVSyncSetupView: View {
        let coordinator: CloudSyncCoordinator
        let model: SyncSetupModel

        @FocusState private var focus: Target?

        private enum Target: Hashable {
            case backend(SyncBackendSelection)
            case lumeCloud(SyncSetupText.LumeCloudOption)
        }

        private var lumeCloudOptions: [SyncSetupText.LumeCloudOption] {
            SyncSetupText.LumeCloudOption.available(hasOfferedAccount: coordinator.offeredLumeCloudAccount != nil)
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let flow = model.flow {
                        TVLumeCloudRouteDetail(route: Self.route(for: flow)) { closeFlow(flow) }
                    } else if model.showsLumeCloud {
                        lumeCloudStep
                    } else {
                        choiceStep
                    }
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
            .tvSettingsBackground()
            .onExitCommand(perform: backAction)
            .onAppear { moveFocus(to: .backend(model.selection)) }
        }

        // MARK: - Choice

        private var choiceStep: some View {
            VStack(alignment: .leading, spacing: 28) {
                header(title: SyncSetupText.title, subtitle: SyncSetupText.subtitle)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.availableBackends, id: \.self) { backend in
                        row(
                            title: SyncSetupText.name(of: backend),
                            detail: SyncSetupText.detail(of: backend),
                            systemImage: SyncSetupText.systemImage(of: backend)
                        ) {
                            if backend == .icloud {
                                Text(SyncSetupText.recommended)
                                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                                    .foregroundStyle(.secondary)
                            } else if backend == .lumecloud {
                                chevron
                            }
                        } action: {
                            choose(backend)
                        }
                        .focused($focus, equals: .backend(backend))
                    }
                }

                if model.isWorking {
                    working
                }

                Text(SyncSetupText.footnote)
                    .tvSettingsSecondaryText()
            }
        }

        private func choose(_ backend: SyncBackendSelection) {
            guard !model.isWorking else { return }
            model.selection = backend
            model.commit(using: coordinator)
            if model.showsLumeCloud, let first = lumeCloudOptions.first {
                moveFocus(to: .lumeCloud(first))
            }
        }

        // MARK: - Lume Cloud

        private var lumeCloudStep: some View {
            VStack(alignment: .leading, spacing: 28) {
                header(title: SyncSettingsPromptText.name(of: .lumecloud), subtitle: SyncSetupText.lumeCloudSubtitle)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lumeCloudOptions, id: \.self) { option in
                        row(title: option.title, detail: option.detail, systemImage: option.systemImage) {
                            if option == .join || option == .restore {
                                chevron
                            }
                        } action: {
                            // Rows stay enabled while a call runs: focus would
                            // otherwise have to leave them.
                            guard !model.isWorking else { return }
                            option.perform(with: model, coordinator: coordinator)
                        }
                        .focused($focus, equals: .lumeCloud(option))
                    }
                }

                if model.isWorking {
                    working
                }
            }
        }

        // MARK: - Flows

        private static func route(for flow: SyncSetupModel.Flow) -> TVLumeCloudRoute {
            switch flow {
            case .join: .join
            case .restore: .restore
            case let .recoveryKey(recoveryKey): .newAccountRecoveryKey(recoveryKey)
            }
        }

        /// A finished flow ends the choice and the screen goes; a cancelled
        /// one returns to the row that opened it.
        private func closeFlow(_ flow: SyncSetupModel.Flow) {
            model.flowDidClose(using: coordinator)
            switch flow {
            case .join: moveFocus(to: .lumeCloud(.join))
            case .restore: moveFocus(to: .lumeCloud(.restore))
            case .recoveryKey: break
            }
        }

        // MARK: - Menu

        /// Nil on the choice itself, so Menu leaves the app as usual. Ignored
        /// while a call runs.
        private var backAction: (() -> Void)? {
            if let flow = model.flow {
                return { if !model.isWorking { closeFlow(flow) } }
            }
            if model.showsLumeCloud {
                return {
                    guard !model.isWorking else { return }
                    model.showsLumeCloud = false
                    moveFocus(to: .backend(.lumecloud))
                }
            }
            return nil
        }

        // MARK: - Building blocks

        private func header(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: TVSettingsMetrics.statusFontSize))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }

        private func row(
            title: LocalizedStringKey,
            detail: LocalizedStringKey,
            systemImage: String,
            @ViewBuilder trailing: () -> some View,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 20) {
                    Image(systemName: systemImage)
                        .font(.system(size: 28, weight: .medium))
                        .frame(width: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                        Text(detail)
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    trailing()
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }

        private var chevron: some View {
            Image(systemName: "chevron.forward")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }

        private var working: some View {
            HStack(spacing: 12) {
                ProgressView()
                Text("Working…")
            }
            .tvSettingsSecondaryText()
        }

        /// Deferred past the render that inserts the target, which would
        /// otherwise drop the write.
        private func moveFocus(to target: Target) {
            Task { @MainActor in focus = target }
        }
    }

#endif
