//
//  TVQuickSwitchOverlay.swift
//  Lume
//
//  The tvOS quick-switch modal: playlists on the left, profiles on the right,
//  a checkmark on the active row of each. Switching only — adding, editing and
//  deleting stay in Settings, which remains the management surface.
//
//  Presented as a plain overlay, never a `fullScreenCover`: a tvOS cover always
//  self-dismisses on Menu, and neither `onExitCommand` nor
//  `interactiveDismissDisabled` stops it.
//

#if os(tvOS)

    import SwiftUI

    struct TVQuickSwitchOverlay: View {
        /// Owns the presentation flag this modal clears to dismiss itself. Handed
        /// in rather than read from the environment: this modal is layered onto
        /// the tab content by `MainTabView`, not nested inside it.
        let router: DeepLinkRouter
        /// Handed in for the same reason, and because `MainTabView` already holds
        /// this fetch — a `@Query` here would register a second store observer
        /// for the identical result.
        let playlists: [Playlist]
        /// The resolved scope `MainTabView` publishes to the tabs, which this
        /// overlay sits outside of.
        let scope: CatalogScope

        /// The roster comes from `ProfileManager` — `UserProfile` lives in the
        /// CloudKit-mirrored store, a separate container the browse `@Query`s
        /// don't bind to.
        @Environment(ProfileManager.self) private var profileManager: ProfileManager?
        @Environment(ParentalControls.self) private var parental: ParentalControls?
        @Environment(PlaylistSwitchModel.self) private var playlistSwitch: PlaylistSwitchModel?
        @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
        @State private var premium = PremiumManager.shared

        /// A profile awaiting PIN entry before the switch goes through.
        @State private var pendingSwitch: UserProfile?
        /// Presented from here rather than after closing: the modal is a plain
        /// overlay, and when the paywall closes focus comes back to the
        /// Combined row it left — unlocked, if the viewer just subscribed.
        @State private var showsPaywall = false

        @FocusState private var focus: FocusTarget?

        private enum FocusTarget: Hashable {
            case combined
            case playlist(UUID)
            case profile(UUID)
        }

        var body: some View {
            let switchColumn = QuickSwitchResolver.playlistColumn(
                playlists,
                scope: scope,
                isPremium: premium.isPremium
            )
            let profileRows = resolvedProfileRows
            let focusTarget = initialFocus(playlists: switchColumn, profiles: profileRows)

            return ZStack {
                Color.black.opacity(0.92)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 28) {
                    Text(
                        "Quick Switch",
                        comment: "Title of the tvOS quick-switch modal, which switches the active playlist or profile"
                    )
                    .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                    .foregroundStyle(.white)

                    HStack(alignment: .top, spacing: 60) {
                        playlistColumn(switchColumn)
                        profileColumn(profileRows)
                    }

                    Text(
                        "Press Menu to close",
                        comment: "Hint at the bottom of the tvOS quick-switch modal telling the viewer which remote button closes it"
                    )
                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, TVSubtitleSearchMetrics.horizontalInset)
                .padding(.vertical, TVSubtitleSearchMetrics.verticalInset)
            }
            .defaultFocus($focus, focusTarget, priority: .userInitiated)
            .onAppear { landInitialFocus(focusTarget) }
            .onExitCommand(perform: close)
            .paywall(isPresented: $showsPaywall, highlight: .multiplePlaylists)
            .pinPrompt(target: $pendingSwitch) { profile in
                guard let profileManager else { return }
                close()
                Task { await profileManager.switchProfile(to: profile.id) }
            }
        }

        // MARK: - Columns

        private func playlistColumn(_ entries: QuickSwitchPlaylistColumn) -> some View {
            let rows = entries.rows
            return column("Playlists", width: TVSettingsMetrics.contentMaxWidth) {
                if rows.isEmpty {
                    emptyLabel(
                        Text(
                            "No playlists yet",
                            comment: "Empty state shown in the playlists column of the tvOS quick-switch modal"
                        )
                    )
                } else {
                    TVCombinedSwitchRow(
                        memberNames: entries.combinedMemberNames,
                        isActive: entries.isCombinedCurrent,
                        isLocked: entries.combinedAction == .paywall
                    ) {
                        selectCombined(entries.combinedAction)
                    }
                    .focused($focus, equals: .combined)

                    ForEach(rows) { row in
                        TVPlaylistSwitchRow(
                            playlist: row.item,
                            isActive: row.isCurrent,
                            isInScope: row.isInScope
                        ) {
                            select(playlist: row)
                        }
                        .focused($focus, equals: .playlist(row.id))
                    }
                }
            }
            .disabled(playlistSwitch?.isSwitching == true)
        }

        private func profileColumn(_ rows: [QuickSwitchRow<UserProfile>]) -> some View {
            column("Profiles", width: TVSettingsMetrics.sideColumnWidth) {
                if rows.isEmpty {
                    emptyLabel(
                        Text(
                            "No profiles yet",
                            comment: "Empty state shown in the profiles column of the tvOS quick-switch modal"
                        )
                    )
                } else {
                    ForEach(rows) { row in
                        TVProfileSwitchRow(profile: row.item, isActive: row.isCurrent) {
                            select(profile: row)
                        }
                        .focused($focus, equals: .profile(row.id))
                    }
                }
            }
            .disabled(profileColumnDisabled)
        }

        /// One column of full-width rows. Its own focus section, so left/right hop
        /// between the two lists rather than walking row by row.
        private func column(
            _ title: LocalizedStringKey,
            width: CGFloat,
            @ViewBuilder rows: () -> some View
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel(title)

                ScrollView {
                    VStack(spacing: 6) {
                        rows()
                    }
                    .padding(.bottom, 24)
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .focusSection()
        }

        private func emptyLabel(_ text: Text) -> some View {
            text
                .tvSettingsSecondaryText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }

        // MARK: - Rows

        private var resolvedProfileRows: [QuickSwitchRow<UserProfile>] {
            guard let profileManager else { return [] }
            return QuickSwitchResolver.profileRows(
                profileManager.profiles,
                activeProfileID: profileManager.activeProfileID
            )
        }

        /// A switch in flight, or a roster that hasn't resolved yet, would leave
        /// the catalog half-projected — the playlist column stays open either way,
        /// including to a child profile.
        private var profileColumnDisabled: Bool {
            guard let profileManager else { return true }
            return profileManager.isSwitching || !profileManager.isReady
        }

        // MARK: - Focus

        /// The selection in effect: the Combined row, or the current playlist.
        /// The first row only stands in when nothing is marked current.
        private func initialFocus(
            playlists column: QuickSwitchPlaylistColumn,
            profiles: [QuickSwitchRow<UserProfile>]
        ) -> FocusTarget? {
            if column.isCombinedCurrent {
                return .combined
            }
            if let row = column.rows.first(where: \.isCurrent) ?? column.rows.first {
                return .playlist(row.id)
            }
            return (profiles.first(where: \.isCurrent) ?? profiles.first).map { .profile($0.id) }
        }

        /// Asserts the initial focus once the tree has mounted: the engine picks
        /// its own target as the rows appear, and a write made in the same turn is
        /// overwritten. Released first — two assertions in flight leave the engine
        /// on the incumbent.
        private func landInitialFocus(_ target: FocusTarget?) {
            guard let target else { return }
            Task { @MainActor in
                focus = nil
                try? await Task.sleep(for: .milliseconds(150))
                focus = target
            }
        }

        // MARK: - Switching

        /// Dismisses the modal. Always called before a switch is applied, so the
        /// switch progress overlay never stacks on top of this one.
        private func close() {
            router.isQuickSwitchPresented = false
        }

        /// Picking the active row just closes the modal.
        private func select(playlist row: QuickSwitchRow<Playlist>) {
            guard !row.isCurrent else {
                close()
                return
            }
            close()
            // The viewer asked to be somewhere else now: land in the cached
            // catalog and leave the due sync to the next launch / foreground.
            playlistSwitch?.deferNextDueSync()
            playlistSwitch.select(row.item.id.uuidString, name: row.item.name, into: $selectedPlaylistID)
        }

        private func selectCombined(_ action: CombinedSwitchAction) {
            switch action {
            case .paywall:
                showsPaywall = true
            case .configure:
                close()
                router.pendingSettingsRoute = .combinedView
                router.selectedTab = .settings
            case .alreadyCurrent:
                close()
            case .switchToCombined:
                // No deferred sync, unlike a playlist row: a member that has
                // never synced would otherwise contribute nothing.
                close()
                playlistSwitch.selectCombined(into: $selectedPlaylistID)
            }
        }

        private func select(profile row: QuickSwitchRow<UserProfile>) {
            guard let profileManager, !row.isCurrent else {
                close()
                return
            }
            if parental?.requiresPIN(toSwitchTo: row.item) == true {
                pendingSwitch = row.item
                return
            }
            close()
            Task { await profileManager.switchProfile(to: row.item.id) }
        }
    }

#endif
