//
//  SettingsView+TVDetail.swift
//  Lume
//
//  The tvOS Settings detail pane: routes the selected sidebar category to its
//  content, plus the two panes (Integrations, Search) simple enough not to
//  warrant their own file.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        /// Content Management brings its own scroll/background, so it replaces the
        /// detail pane wholesale rather than nesting inside the scrolling detail.
        @ViewBuilder
        var tvDetailContainer: some View {
            switch selectedCategory {
            case .content:
                ParentalGateView { ContentManagementView() }
                    .focusSection()
            default:
                tvDetail
            }
        }

        var tvDetail: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    switch selectedCategory {
                    case .premium:
                        tvPremiumDetail
                    case .playlists:
                        if let selectedPlaylist {
                            PlaylistDetailView(playlist: selectedPlaylist) {
                                self.selectedPlaylist = nil
                            }
                        } else {
                            tvPlaylistsDetail
                        }
                    case .profiles: TVProfilesSettingsView()
                    case .home: tvHomeLayoutDetail
                    case .sports: TVSportsSettingsPane()
                    case .epg: EPGSettingsView()
                    case .search: tvSearchDetail
                    case .storage: StorageManagementView()
                    case .integrations: tvIntegrationsDetail
                    case .player:
                        if let selectedEngineOptions {
                            tvEngineOptionsDetail(for: selectedEngineOptions)
                        } else if let preferredLanguagePane {
                            tvPreferredLanguageDetail(preferredLanguagePane)
                        } else {
                            tvPlayerDetail
                        }
                    case .about: tvAboutDetail
                    case .content: EmptyView() // handled by tvDetailContainer
                    }
                }
                .frame(maxWidth: TVSettingsMetrics.detailMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.vertical, 72)
            }
            .focusSection()
        }

        private var tvIntegrationsDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                if trakt.isConfigured {
                    TVTraktIntegrationView()
                }
                if simkl.isConfigured {
                    TVSimklIntegrationView()
                }
                if openSubtitles.isConfigured {
                    TVOpenSubtitlesIntegrationView()
                }
            }
        }

        private var tvSearchDetail: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Search")
                TVOptionToggleRow(title: "Search All Playlists", isOn: $searchAllPlaylists)
                Text("When off, search only finds content in the active playlist. Turn this on to search across all your playlists.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }
    }

#endif
