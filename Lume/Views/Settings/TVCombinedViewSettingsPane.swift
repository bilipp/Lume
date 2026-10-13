//
//  TVCombinedViewSettingsPane.swift
//  Lume
//
//  tvOS Settings › Playlists › Combined View, swapped into the detail pane in
//  place: the members in priority order (Select lifts one to reorder, its
//  pencil opens it), the playlists not in it, and a member's detail with its content
//  types stacked vertically. The config syncs through iCloud; choosing
//  Combined stays per device (Quick Switch).
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    /// A Combined View member in `TVReorderableContentList`: its name and the
    /// types it contributes.
    struct CombinedMemberRow: ReorderableRowItem {
        let playlist: Playlist

        var id: String {
            playlist.id.uuidString
        }

        var title: String {
            "\(playlist.name) · \(playlist.combinedTabs.summary)"
        }
    }

    struct TVCombinedViewSettingsPane: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        @Query(sort: \Playlist.addedAt) private var playlists: [Playlist]
        @State private var premium = PremiumManager.shared
        /// True while a member is lifted: everything else is disabled so the
        /// remote's up/down move it, and nothing is written until it's placed.
        @State private var isReordering = false
        @State private var detailID: UUID?

        /// Hands focus across a swap between the list and a detail, which
        /// removes the focused row (`SettingsView.beginContentManagementHandoff`).
        let beginHandoff: () -> Void

        /// Playlists from a newer build's unknown source type can never be
        /// members, so they are not offered.
        private var nonMembers: [Playlist] {
            playlists.filter { $0.knownSourceType != nil && !$0.isCombinedMember }
        }

        private var detailPlaylist: Playlist? {
            detailID.flatMap { id in playlists.first { $0.id == id } }
        }

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let detailPlaylist {
                            detail(detailPlaylist)
                        } else {
                            list(proxy: proxy)
                        }
                    }
                    .frame(maxWidth: TVSettingsMetrics.detailMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 72)
                }
            }
            .tvSettingsBackground()
        }

        // MARK: - List

        @ViewBuilder
        private func list(proxy: ScrollViewProxy) -> some View {
            let members = playlists.combinedMembers.map(CombinedMemberRow.init)

            Text("Combined View")
                .font(.system(size: 34, weight: .bold))
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)

            if !members.isEmpty {
                memberSection(members, proxy: proxy)
            }

            if !nonMembers.isEmpty {
                nonMemberSection
            }

            VStack(alignment: .leading, spacing: 8) {
                // swiftlint:disable:next line_length
                Text("Combined View merges the content types you choose from each playlist into one library, grouped by playlist. Include at least two playlists, then choose Combined in Quick Switch (Play/Pause).")
                if !premium.isPremium {
                    Text("Combined View is part of Lume Pro. Your choices here are kept.")
                }
            }
            .font(.system(size: 20))
            .foregroundStyle(.secondary)
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }

        private func memberSection(_ members: [CombinedMemberRow], proxy: ScrollViewProxy) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Priority")
                Group {
                    if isReordering {
                        Text("Move up or down to position, then select to place. Press Menu to cancel.")
                    } else {
                        Text("Select a playlist to move it. Select its pencil to choose its content types.")
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.bottom, 4)
                TVReorderableContentList(
                    items: members,
                    title: \.title,
                    isHidden: { _ in false },
                    onToggleHidden: nil,
                    onCommitOrder: commitOrder,
                    isReordering: $isReordering,
                    scrollProxy: proxy,
                    onEdit: { open($0.playlist) }
                )
            }
        }

        private var nonMemberSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Not Included")
                ForEach(nonMembers) { playlist in
                    Button {
                        open(playlist)
                    } label: {
                        HStack(spacing: 16) {
                            Text(verbatim: playlist.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                }
            }
            .disabled(isReordering)
        }

        // MARK: - Detail

        /// Toggles stacked vertically so only up/down move focus; Menu returns
        /// to the list.
        private func detail(_ playlist: Playlist) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: playlist.name)
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.bottom, 20)

                TVOptionToggleRow(title: "Include in Combined View", isOn: inclusion(of: playlist))
                    .accessibilityLabel(Text("Include \(playlist.name) in Combined View"))
                    .accessibilityValue(Text(playlist.isCombinedMember ? "On" : "Off"))

                if playlist.isCombinedMember {
                    ForEach(PlaylistTab.allCases) { tab in
                        let isOn = contribution(of: tab, from: playlist)
                        TVOptionToggleRow(title: tab.title, isOn: isOn)
                            .accessibilityLabel(Text("Include \(tab.spokenName) from \(playlist.name)"))
                            .accessibilityValue(Text(isOn.wrappedValue ? "On" : "Off"))
                    }
                }
            }
            .focusSection()
            .onExitCommand(perform: closeDetail)
        }

        private func open(_ playlist: Playlist) {
            beginHandoff()
            detailID = playlist.id
        }

        private func closeDetail() {
            beginHandoff()
            detailID = nil
        }

        // MARK: - Writes

        private func inclusion(of playlist: Playlist) -> Binding<Bool> {
            playlist.combinedInclusion(among: playlists, context: modelContext, cloudSync: cloudSync)
        }

        private func contribution(of tab: PlaylistTab, from playlist: Playlist) -> Binding<Bool> {
            playlist.combinedContribution(tab, among: playlists, context: modelContext, cloudSync: cloudSync)
        }

        private func commitOrder(_ rows: [CombinedMemberRow]) {
            rows.map(\.playlist).commitCombinedPriority(context: modelContext, cloudSync: cloudSync)
        }
    }

#endif
