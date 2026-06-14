import SwiftData
import SwiftUI

/// The top-left profile switcher: the active profile's avatar, tapping it opens
/// a menu to switch profile or manage profiles. iOS / macOS only — tvOS surfaces
/// profiles through Settings to avoid disturbing the immersive home's focus.
///
/// Hidden while there's only a single profile: there's nothing to switch to, and
/// creating more profiles stays reachable through Settings.
struct ProfileMenu: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query(sort: [SortDescriptor(\UserProfile.sortOrder), SortDescriptor(\UserProfile.createdAt)])
    private var profiles: [UserProfile]

    @State private var managing = false

    var body: some View {
        if let profileManager, profiles.count > 1 {
            let active = profiles.first { $0.id == profileManager.activeProfileID }
            Menu {
                ForEach(profiles) { profile in
                    Button {
                        Task { await profileManager.switchProfile(to: profile.id) }
                    } label: {
                        Label(
                            profile.name,
                            systemImage: profile.id == profileManager.activeProfileID ? "checkmark" : profile.symbolName
                        )
                    }
                }

                Divider()

                Button {
                    managing = true
                } label: {
                    Label("Manage Profiles", systemImage: "person.2.fill")
                }
            } label: {
                ProfileAvatarView(
                    symbolName: active?.symbolName ?? UserProfile.defaultSymbol,
                    tint: active?.tint ?? .blue,
                    size: 30
                )
            }
            .disabled(profileManager.isSwitching)
            .accessibilityLabel("Profile: \(active?.name ?? "")")
            .sheet(isPresented: $managing) {
                NavigationStack {
                    ManageProfilesView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { managing = false }
                            }
                        }
                }
                // A macOS sheet sizes to its content's ideal size, and a `List`
                // reports no useful intrinsic height — so without an explicit
                // frame the sheet collapses to just the title bar. Match the
                // sizing SettingsView uses for the same screen.
                #if os(macOS)
                .frame(minWidth: 480, idealWidth: 540, minHeight: 400, idealHeight: 520)
                #endif
            }
        }
    }
}

extension View {
    /// Places the ``ProfileMenu`` in the navigation bar's leading edge. Shared by
    /// the top-level library screens (Home, Movies, Series). iOS / macOS only —
    /// tvOS surfaces profiles through Settings.
    func profileMenuToolbar() -> some View {
        #if os(iOS)
            toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ProfileMenu()
                }
            }
        #elseif os(macOS)
            toolbar {
                ToolbarItem(placement: .navigation) {
                    ProfileMenu()
                }
            }
        #else
            self
        #endif
    }
}
