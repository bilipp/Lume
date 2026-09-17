//
//  SettingsView+Profiles.swift
//  Lume
//
//  The tvOS Profiles settings pane — the management surface: switch, add, edit
//  and delete profiles. Switching alone also has a fast path, the Play/Pause
//  quick-switch overlay (TVQuickSwitchOverlay). tvOS carries no top-left
//  ProfileMenu (it would disturb the immersive home's focus); iOS/macOS use that
//  menu instead.
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
        @Environment(ParentalControls.self) private var parental: ParentalControls?
        /// The roster comes from `ProfileManager` — `UserProfile` lives in the
        /// cloud store (a separate container this view's env context doesn't bind
        /// to) — and which row is active is resolved the same way every other
        /// switch surface resolves it.
        private var profileRows: [QuickSwitchRow<UserProfile>] {
            guard let profileManager else { return [] }
            return QuickSwitchResolver.profileRows(
                profileManager.profiles,
                activeProfileID: profileManager.activeProfileID
            )
        }

        @State private var creatingProfile = false
        @State private var editingProfile: UserProfile?
        @State private var pendingSwitch: UserProfile?
        @State private var pinFlow: ParentalPINFlow?
        /// Multiple profiles are a Premium feature; free users keep one profile.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @AppStorage(ProfileSettings.askOnStartupKey) private var askOnStartup = ProfileSettings.askOnStartupDefault

        var body: some View {
            // A child profile can't manage profiles (it could otherwise edit
            // itself to drop the child flag); the PIN unlocks the pane, same as
            // Content Management. A parent passes straight through.
            ParentalGateView(subtitle: "Enter your PIN to manage profiles.") {
                profilesPane
            }
        }

        private var profilesPane: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Profiles")

                ForEach(profileRows) { profileRow in
                    row(profileRow)
                }

                Button {
                    if premium.isPremium || profileRows.isEmpty {
                        creatingProfile = true
                    } else {
                        showPaywall = true
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: premium.isPremium ? "plus" : "crown")
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

                parentalControls
            }
            .fullScreenCover(isPresented: $creatingProfile) {
                ProfileEditorView()
            }
            .fullScreenCover(item: $editingProfile) { profile in
                ProfileEditorView(profile: profile)
            }
            .paywall(isPresented: $showPaywall, highlight: .multipleProfiles)
            .pinPrompt(target: $pendingSwitch) { profile in
                Task { await profileManager?.switchProfile(to: profile.id) }
            }
            .fullScreenCover(item: $pinFlow) { flow in
                ParentalPINFlowView(flow: flow) { pinFlow = nil }
            }
        }

        @ViewBuilder
        private var parentalControls: some View {
            TVSettingsSectionLabel("Parental Controls")
                .padding(.top, 24)

            if parental?.isPINSet == true {
                Button { pinFlow = .change } label: {
                    parentalRowLabel("Change PIN", systemImage: "lock.rotation")
                }
                .buttonStyle(TVSettingsRowButtonStyle())

                Button { pinFlow = .remove } label: {
                    parentalRowLabel("Turn Off PIN", systemImage: "lock.open")
                }
                .buttonStyle(TVSettingsRowButtonStyle())
            } else {
                Button { pinFlow = .set } label: {
                    parentalRowLabel("Set a PIN", systemImage: "lock")
                }
                .buttonStyle(TVSettingsRowButtonStyle())
            }

            Text("A PIN is required to switch away from a child profile and to open Content Management.")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.top, 6)
        }

        private func parentalRowLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                Text(title)
                Spacer(minLength: 0)
            }
        }

        private func row(_ profileRow: QuickSwitchRow<UserProfile>) -> some View {
            let profile = profileRow.item
            return HStack(spacing: 16) {
                TVProfileSwitchRow(profile: profile, isActive: profileRow.isCurrent) {
                    guard let profileManager, !profileRow.isCurrent else { return }
                    if parental?.requiresPIN(toSwitchTo: profile) == true {
                        pendingSwitch = profile
                    } else {
                        Task { await profileManager.switchProfile(to: profile.id) }
                    }
                }

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
