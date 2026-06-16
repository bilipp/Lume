import SwiftData
import SwiftUI

/// The launch-time "Who's watching?" chooser. Shown before the main UI when the
/// user has enabled "Ask on Startup" (off by default) and more than one profile
/// exists. Picking a profile switches to it (if it isn't already active) and
/// hands control back to `ContentView` via `onComplete`.
struct ProfileSelectionView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ParentalControls.self) private var parental: ParentalControls?
    /// The roster comes from `ProfileManager` — `UserProfile` lives in the cloud
    /// store (a separate container this view's env context doesn't bind to).
    private var profiles: [UserProfile] {
        profileManager?.profiles ?? []
    }

    /// A profile awaiting PIN entry before the switch goes through (leaving a
    /// child profile for a non-child one).
    @State private var pendingSwitch: UserProfile?

    /// Called once a profile has been chosen (and any switch kicked off).
    let onComplete: () -> Void

    #if os(tvOS)
        private let avatarSize: CGFloat = 180
        private let gridSpacing: CGFloat = 64
        private let titleFont: Font = .system(size: 56, weight: .semibold)
        private let maxColumns = 6
    #else
        private let avatarSize: CGFloat = 96
        private let gridSpacing: CGFloat = 28
        private let titleFont: Font = .largeTitle.weight(.semibold)
        private let maxColumns = 4
    #endif

    /// A fixed number of fixed-width columns (capped at `maxColumns`) gives the
    /// grid a determinate intrinsic width, so the centered parent `VStack`
    /// centers the whole block instead of letting an adaptive grid stretch
    /// full-width and pack items against the leading edge. Rows still wrap.
    private var columns: [GridItem] {
        let count = max(1, min(profiles.count, maxColumns))
        return Array(repeating: GridItem(.fixed(avatarSize + 48), spacing: gridSpacing), count: count)
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
        .pinPrompt(target: $pendingSwitch) { profile in
            Task { await profileManager?.switchProfile(to: profile.id) }
            onComplete()
        }
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
        guard let profileManager, profile.id != profileManager.activeProfileID else {
            onComplete()
            return
        }
        if parental?.requiresPIN(toSwitchTo: profile) == true {
            pendingSwitch = profile
        } else {
            Task { await profileManager.switchProfile(to: profile.id) }
            onComplete()
        }
    }
}
