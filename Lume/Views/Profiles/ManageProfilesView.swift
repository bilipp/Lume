import SwiftData
import SwiftUI

/// List of profiles with switch / add / edit / delete. Used as a standalone
/// screen from the profile switcher and embedded in Settings.
struct ManageProfilesView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ParentalControls.self) private var parental: ParentalControls?
    /// The roster comes from `ProfileManager` — `UserProfile` lives in the cloud
    /// store (a separate container this view's env context doesn't bind to).
    private var profiles: [UserProfile] {
        profileManager?.profiles ?? []
    }

    @State private var creatingProfile = false
    @State private var editingProfile: UserProfile?
    @State private var profilePendingDeletion: UserProfile?
    /// A profile awaiting PIN entry before the switch goes through.
    @State private var pendingSwitch: UserProfile?
    /// The PIN operation being run (set / change / turn off).
    @State private var pinFlow: ParentalPINFlow?

    @AppStorage(ProfileSettings.askOnStartupKey) private var askOnStartup = ProfileSettings.askOnStartupDefault

    var body: some View {
        // A child profile can't manage profiles (it could otherwise edit itself
        // to drop the child flag); the PIN unlocks the screen, same as Content
        // Management. A parent passes straight through.
        ParentalGateView(subtitle: "Enter your PIN to manage profiles.") {
            managementList
        }
    }

    private var managementList: some View {
        List {
            Section {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
            } footer: {
                Text("Each profile keeps its own watch history, progress and favorites. Profiles sync across your devices via iCloud.")
            }

            Section {
                Button {
                    creatingProfile = true
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
            }

            Section {
                Toggle("Ask on Startup", isOn: $askOnStartup)
            } footer: {
                Text("Choose a profile each time Lume launches. When off, Lume resumes the last profile you used.")
            }

            parentalControlsSection
        }
        .platformNavigationTitle("Profiles")
        .pinPrompt(target: $pendingSwitch) { profile in
            Task { await profileManager?.switchProfile(to: profile.id) }
        }
        // Attached to the List (not a Section): a sheet attached to a Section
        // inside a List presents then immediately dismisses.
        .sheet(item: $pinFlow) { flow in
            NavigationStack {
                ParentalPINFlowView(flow: flow) { pinFlow = nil }
                    .platformNavigationTitle("Parental Controls")
            }
            #if os(macOS)
            .frame(minWidth: 380, idealWidth: 420, minHeight: 460, idealHeight: 520)
            #endif
        }
        .sheet(isPresented: $creatingProfile) {
            ProfileEditorView()
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(profile: profile)
        }
        .alert(
            "Delete Profile?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            presenting: profilePendingDeletion
        ) { profile in
            Button("Delete", role: .destructive) {
                guard let profileManager else { return }
                Task { await profileManager.deleteProfile(profile) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("This permanently removes \(profile.name)'s watch history, progress and favorites. Your library is not affected.")
        }
    }

    private var parentalControlsSection: some View {
        Section {
            if parental?.isPINSet == true {
                Button {
                    pinFlow = .change
                } label: {
                    Label("Change PIN", systemImage: "lock.rotation")
                }
                Button(role: .destructive) {
                    pinFlow = .remove
                } label: {
                    Label("Turn Off PIN", systemImage: "lock.open")
                }
            } else {
                Button {
                    pinFlow = .set
                } label: {
                    Label("Set a PIN", systemImage: "lock")
                }
            }
        } header: {
            Text("Parental Controls")
        } footer: {
            Text("A PIN is required to switch away from a child profile and to open Content Management. Mark a profile as a child profile by editing it.")
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: UserProfile) -> some View {
        let isActive = profile.id == profileManager?.activeProfileID
        Button {
            guard let profileManager, !isActive else { return }
            if parental?.requiresPIN(toSwitchTo: profile) == true {
                pendingSwitch = profile
            } else {
                Task { await profileManager.switchProfile(to: profile.id) }
            }
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(profile: profile, size: 36)
                Text(profile.name)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editingProfile = profile } label: { Label("Edit", systemImage: "pencil") }
            if profiles.count > 1 {
                Button(role: .destructive) {
                    profilePendingDeletion = profile
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        #if !os(tvOS)
        .swipeActions(edge: .trailing) {
            if profiles.count > 1 {
                Button(role: .destructive) {
                    profilePendingDeletion = profile
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button {
                editingProfile = profile
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.indigo)
        }
        #endif
    }
}
