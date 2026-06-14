import SwiftData
import SwiftUI

/// List of profiles with switch / add / edit / delete. Used as a standalone
/// screen from the profile switcher and embedded in Settings.
struct ManageProfilesView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query(sort: [SortDescriptor(\UserProfile.sortOrder), SortDescriptor(\UserProfile.createdAt)])
    private var profiles: [UserProfile]

    @State private var creatingProfile = false
    @State private var editingProfile: UserProfile?
    @State private var profilePendingDeletion: UserProfile?

    @AppStorage(ProfileSettings.askOnStartupKey) private var askOnStartup = ProfileSettings.askOnStartupDefault

    var body: some View {
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
        }
        .platformNavigationTitle("Profiles")
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

    @ViewBuilder
    private func profileRow(_ profile: UserProfile) -> some View {
        let isActive = profile.id == profileManager?.activeProfileID
        Button {
            guard let profileManager, !isActive else { return }
            Task { await profileManager.switchProfile(to: profile.id) }
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
