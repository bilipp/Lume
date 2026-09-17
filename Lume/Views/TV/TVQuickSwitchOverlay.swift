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

        /// The roster comes from `ProfileManager` — `UserProfile` lives in the
        /// CloudKit-mirrored store, a separate container the browse `@Query`s
        /// don't bind to.
        @Environment(ProfileManager.self) private var profileManager: ProfileManager?
        @Environment(ParentalControls.self) private var parental: ParentalControls?
        @Environment(PlaylistSwitchModel.self) private var playlistSwitch: PlaylistSwitchModel?
        @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

        /// A profile awaiting PIN entry before the switch goes through.
        @State private var pendingSwitch: UserProfile?

        @FocusState private var focus: FocusTarget?

        private enum FocusTarget: Hashable {
            case playlist(UUID)
            case profile(UUID)
        }

        var body: some View {
            let playlistRows = QuickSwitchResolver.playlistRows(playlists, storedID: selectedPlaylistID)
            let profileRows = resolvedProfileRows
            let focusTarget = initialFocus(playlists: playlistRows, profiles: profileRows)

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
                        playlistColumn(playlistRows)
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
            .pinPrompt(target: $pendingSwitch) { profile in
                guard let profileManager else { return }
                close()
                Task { await profileManager.switchProfile(to: profile.id) }
            }
        }

        // MARK: - Columns

        private func playlistColumn(_ rows: [QuickSwitchRow<Playlist>]) -> some View {
            column("Playlists", width: TVSettingsMetrics.contentMaxWidth) {
                if rows.isEmpty {
                    emptyLabel(
                        Text(
                            "No playlists yet",
                            comment: "Empty state shown in the playlists column of the tvOS quick-switch modal"
                        )
                    )
                } else {
                    ForEach(rows) { row in
                        TVPlaylistSwitchRow(playlist: row.item, isActive: row.isCurrent) {
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

        private func initialFocus(
            playlists: [QuickSwitchRow<Playlist>],
            profiles: [QuickSwitchRow<UserProfile>]
        ) -> FocusTarget? {
            if let first = playlists.first {
                return .playlist(first.id)
            }
            return profiles.first.map { .profile($0.id) }
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
            let id = row.item.id.uuidString
            let name = row.item.name
            close()
            if let playlistSwitch {
                // The viewer asked to be somewhere else now: land in the cached
                // catalog and leave the due sync to the next launch / foreground.
                playlistSwitch.deferNextDueSync()
                playlistSwitch.switchTo(name: name) { selectedPlaylistID = id }
            } else {
                selectedPlaylistID = id
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
