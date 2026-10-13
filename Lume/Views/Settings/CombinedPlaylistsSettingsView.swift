//
//  CombinedPlaylistsSettingsView.swift
//  Lume
//
//  Settings › Playlists › Combined View: which playlists the Combined
//  selection merges, the content types each contributes, and their priority.
//  The config syncs through iCloud; choosing Combined stays per device.
//

import SwiftData
import SwiftUI

#if !os(tvOS)

    struct CombinedPlaylistsSettingsView: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        @Query(sort: \Playlist.addedAt) private var playlists: [Playlist]
        @State private var premium = PremiumManager.shared

        /// Playlists from a newer build's unknown source type can never be
        /// members, so they are not offered.
        private var candidates: [Playlist] {
            playlists.filter { $0.knownSourceType != nil }
        }

        var body: some View {
            let members = playlists.combinedMembers
            List {
                if !members.isEmpty {
                    Section {
                        ForEach(members) { playlist in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: playlist.name)
                                Text(verbatim: playlist.combinedTabs.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onMove { offsets, destination in
                            move(members, from: offsets, to: destination)
                        }
                    } header: {
                        Text("Priority")
                    } footer: {
                        Text("Each playlist's categories appear in this order. Drag to reorder.")
                    }
                }

                if candidates.isEmpty {
                    Section {
                        Text("No playlists yet. Add your IPTV provider to start streaming.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(candidates) { playlist in
                    playlistSection(playlist)
                }

                Section {} footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        // swiftlint:disable:next line_length
                        Text("Combined View merges the content types you choose from each playlist into one library, grouped by playlist. Include at least two playlists, then choose Combined in the playlist switcher.")
                        if !premium.isPremium {
                            Text("Combined View is part of Lume Pro. Your choices here are kept.")
                        }
                    }
                }
            }
            .platformNavigationTitle("Combined View")
            .alwaysEditing()
        }

        private func playlistSection(_ playlist: Playlist) -> some View {
            Section {
                Toggle("Include in Combined View", isOn: inclusion(of: playlist))
                    .accessibilityLabel(Text("Include \(playlist.name) in Combined View"))
                if playlist.isCombinedMember {
                    ForEach(PlaylistTab.allCases) { tab in
                        Toggle(tab.title, isOn: contribution(of: tab, from: playlist))
                            .accessibilityLabel(Text("Include \(tab.spokenName) from \(playlist.name)"))
                    }
                }
            } header: {
                Text(verbatim: playlist.name)
            }
        }

        private func inclusion(of playlist: Playlist) -> Binding<Bool> {
            playlist.combinedInclusion(among: playlists, context: modelContext, cloudSync: cloudSync)
        }

        private func contribution(of tab: PlaylistTab, from playlist: Playlist) -> Binding<Bool> {
            playlist.combinedContribution(tab, among: playlists, context: modelContext, cloudSync: cloudSync)
        }

        private func move(_ members: [Playlist], from offsets: IndexSet, to destination: Int) {
            var ordered = members
            ordered.move(fromOffsets: offsets, toOffset: destination)
            ordered.commitCombinedPriority(context: modelContext, cloudSync: cloudSync)
        }
    }

    private extension View {
        /// Keeps the priority rows draggable without an Edit button; toggles
        /// stay interactive. macOS lists make `onMove` rows draggable on their own.
        func alwaysEditing() -> some View {
            #if os(iOS) || os(visionOS)
                environment(\.editMode, .constant(.active))
            #else
                self
            #endif
        }
    }

#endif
