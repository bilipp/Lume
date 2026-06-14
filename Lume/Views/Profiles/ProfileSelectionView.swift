import SwiftData
import SwiftUI

/// The launch-time "Who's watching?" chooser. Shown before the main UI when the
/// user has enabled "Ask on Startup" (off by default) and more than one profile
/// exists. Picking a profile switches to it (if it isn't already active) and
/// hands control back to `ContentView` via `onComplete`.
struct ProfileSelectionView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query(sort: [SortDescriptor(\UserProfile.sortOrder), SortDescriptor(\UserProfile.createdAt)])
    private var profiles: [UserProfile]

    /// Called once a profile has been chosen (and any switch kicked off).
    let onComplete: () -> Void

    #if os(tvOS)
        private let avatarSize: CGFloat = 180
        private let gridSpacing: CGFloat = 64
        private let titleFont: Font = .system(size: 56, weight: .semibold)
    #else
        private let avatarSize: CGFloat = 96
        private let gridSpacing: CGFloat = 28
        private let titleFont: Font = .largeTitle.weight(.semibold)
    #endif

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: avatarSize + 48), spacing: gridSpacing)]
    }

    var body: some View {
        VStack(spacing: gridSpacing) {
            Text("Who's Watching?")
                .font(titleFont)

            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(profiles) { profile in
                    profileButton(profile)
                }
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }

    @ViewBuilder
    private var background: some View {
        #if os(tvOS)
            TVSettingsMetrics.background.ignoresSafeArea()
        #else
            Color.clear
        #endif
    }

    private func profileButton(_ profile: UserProfile) -> some View {
        let isActive = profile.id == profileManager?.activeProfileID
        return Button {
            select(profile)
        } label: {
            VStack(spacing: 14) {
                ProfileAvatarView(profile: profile, size: avatarSize)
                Text(profile.name)
                    .font(.headline)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.name)
    }

    private func select(_ profile: UserProfile) {
        if let profileManager, profile.id != profileManager.activeProfileID {
            Task { await profileManager.switchProfile(to: profile.id) }
        }
        onComplete()
    }
}
