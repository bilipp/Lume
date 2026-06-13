//
//  SettingsView+TVComponents.swift
//  Lume
//
//  The tvOS sidebar categories, the About detail pane, and the SwiftUI previews,
//  split out of SettingsView to keep that file within the project's size limit.
//

import SwiftData
import SwiftUI

#if os(tvOS)

    // MARK: - tvOS settings categories

    /// The top-level settings categories shown in the tvOS sidebar.
    enum SettingsCategory: String, CaseIterable, Identifiable {
        case playlists, content, integrations, player, about

        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            switch self {
            case .playlists: "Playlists"
            case .content: "Content"
            case .integrations: "Integrations"
            case .player: "Player"
            case .about: "About"
            }
        }
    }

    extension SettingsView {
        var tvAboutDetail: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("About")

                HStack(spacing: 18) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .frame(width: 60, height: 60)
                        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lume")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Version 1.0.0")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.vertical, 8)
            }
        }
    }

#endif

#Preview("Empty") {
    SettingsView()
}

#Preview("With Playlists") {
    SettingsView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                let backup = Playlist(name: "Backup", serverURL: "http://backup.com:8080", username: "user2", password: "pass2")
                container.mainContext.insert(playlist)
                container.mainContext.insert(backup)
            }
        }
}
