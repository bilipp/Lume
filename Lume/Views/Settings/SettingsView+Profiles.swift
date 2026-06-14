//
//  SettingsView+Profiles.swift
//  Lume
//
//  The tvOS Profiles settings pane. tvOS has no top-left profile switcher (it
//  would disturb the immersive home's focus), so Settings is the entry point for
//  switching, adding and editing profiles there. iOS/macOS use the top-left
//  ProfileMenu instead.
//

import SwiftData
import SwiftUI

#if !os(tvOS)

    extension SettingsView {
        /// The iOS/macOS Settings entry into profile management (switch / add /
        /// edit / delete). The top-left `ProfileMenu` is the quick switcher; this
        /// is the dedicated management surface. Lives here (not in SettingsView.swift)
        /// to keep that file within the project's line-count cap.
        var profilesSection: some View {
            Section {
                NavigationLink {
                    ManageProfilesView()
                } label: {
                    HStack(spacing: 12) {
                        if let activeProfile = profileManager?.activeProfile {
                            ProfileAvatarView(profile: activeProfile, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Profiles")
                                Text(activeProfile.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Label("Profiles", systemImage: "person.crop.circle")
                        }
                    }
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Each profile keeps its own watch history, progress and favorites. Profiles sync across your devices via iCloud.")
            }
        }
    }

#endif

#if os(tvOS)

    /// Self-contained Profiles pane shown in the tvOS Settings detail column.
    struct TVProfilesSettingsView: View {
        @Environment(ProfileManager.self) private var profileManager: ProfileManager?
        @Query(sort: [SortDescriptor(\UserProfile.sortOrder), SortDescriptor(\UserProfile.createdAt)])
        private var profiles: [UserProfile]
        @State private var creatingProfile = false
        @State private var editingProfile: UserProfile?
        @AppStorage(ProfileSettings.askOnStartupKey) private var askOnStartup = ProfileSettings.askOnStartupDefault

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Profiles")

                ForEach(profiles) { profile in
                    row(profile)
                }

                Button {
                    creatingProfile = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                        Text("Add Profile")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())

                Text("Each profile keeps its own watch history, progress and favorites, synced across your devices.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)

                TVSettingsSectionLabel("Startup")
                    .padding(.top, 24)

                TVOptionToggleRow(title: "Ask on Startup", isOn: $askOnStartup)

                Text("Choose a profile each time Lume launches. When off, Lume resumes the last profile you used.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
            .fullScreenCover(isPresented: $creatingProfile) {
                ProfileEditorView()
            }
            .fullScreenCover(item: $editingProfile) { profile in
                ProfileEditorView(profile: profile)
            }
        }

        private func row(_ profile: UserProfile) -> some View {
            let isActive = profile.id == profileManager?.activeProfileID
            return HStack(spacing: 16) {
                Button {
                    guard let profileManager, !isActive else { return }
                    Task { await profileManager.switchProfile(to: profile.id) }
                } label: {
                    HStack(spacing: 16) {
                        ProfileAvatarView(profile: profile, size: 44)
                        Text(profile.name)
                        Spacer(minLength: 0)
                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())

                Button {
                    editingProfile = profile
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(TVContentIconButtonStyle())
                .accessibilityLabel("Edit \(profile.name)")
            }
        }
    }

#endif
