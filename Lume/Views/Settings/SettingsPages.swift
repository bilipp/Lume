//
//  SettingsPages.swift
//  Lume
//
//  The smaller iOS / macOS / visionOS pages behind root Settings rows:
//  Appearance, Downloads and Connected Services (Trakt, Simkl). tvOS has no Appearance or
//  Downloads, and shows Connected Services in its own pane.
//

#if !os(tvOS)

    import SwiftUI

    /// The app-wide appearance override (System / Dark / Light), applied at the
    /// scene root in `LumeApp`.
    struct AppearanceSettingsView: View {
        @AppStorage(AppAppearance.storageKey)
        private var appearanceRaw = AppAppearance.defaultValue.rawValue

        var body: some View {
            List {
                Section {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("Follow the device appearance, or keep Lume always in Dark or Light Mode.")
                }
            }
            .platformNavigationTitle("Appearance")
        }
    }

    struct DownloadsSettingsView: View {
        @AppStorage(DownloadManager.maxConcurrentKey) private var maxConcurrent = 1
        @AppStorage(DownloadManager.autoDeleteKey) private var autoDeleteAfterWatching = false

        var body: some View {
            List {
                Section {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        Label("Manage Downloads", systemImage: "arrow.down.circle")
                    }
                }

                Section {
                    Stepper(
                        "Max Simultaneous Downloads: \(maxConcurrent)",
                        value: $maxConcurrent,
                        in: 1 ... 5
                    )

                    Toggle("Auto-Delete After Watching", isOn: $autoDeleteAfterWatching)
                } footer: {
                    Text("Download movies and episodes for offline playback. Auto-delete removes the file once you've finished watching.")
                }
            }
            .platformNavigationTitle("Downloads")
        }
    }

    /// Trakt and Simkl — whichever this build has credentials for. OpenSubtitles
    /// lives under Player.
    struct ConnectedServicesView: View {
        @State private var trakt = TraktService.shared
        @State private var simkl = SimklService.shared

        var body: some View {
            List {
                Section {
                    if trakt.isConfigured {
                        NavigationLink {
                            TraktIntegrationView()
                        } label: {
                            serviceLabel(
                                "Trakt",
                                systemImage: "arrow.trianglehead.2.clockwise.rotate.90.circle",
                                status: trakt.isConnected ? trakt.username.map { "@\($0)" } ?? String(localized: "Connected") : nil
                            )
                        }
                    }

                    if simkl.isConfigured {
                        NavigationLink {
                            SimklIntegrationView()
                        } label: {
                            serviceLabel(
                                "Simkl",
                                systemImage: "arrow.trianglehead.2.clockwise.rotate.90.circle",
                                status: simkl.isConnected ? simkl.username.map { "@\($0)" } ?? String(localized: "Connected") : nil
                            )
                        }
                    }

                } footer: {
                    Text("Sync watched movies and episodes and show your Trakt or Simkl watchlist on Home.")
                }
            }
            .platformNavigationTitle("Connected Services")
        }

        private func serviceLabel(_ title: LocalizedStringKey, systemImage: String, status: String?) -> some View {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let status {
                    Text(verbatim: status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

#endif
