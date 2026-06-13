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

#if os(tvOS)

    /// Self-contained Profiles pane shown in the tvOS Settings detail column.
    struct TVProfilesSettingsView: View {
        @Environment(ProfileManager.self) private var profileManager: ProfileManager?
        @Query(sort: [SortDescriptor(\UserProfile.sortOrder), SortDescriptor(\UserProfile.createdAt)])
        private var profiles: [UserProfile]
        @State private var creatingProfile = false
        @State private var editingProfile: UserProfile?

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
