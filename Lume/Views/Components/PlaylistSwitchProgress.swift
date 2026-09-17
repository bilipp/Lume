import SwiftUI

/// Tracks an in-flight global playlist switch so the UI can show a brief blocking
/// overlay while the content tabs re-render for the newly-selected playlist.
///
/// Switching playlist flips a single `@AppStorage` value that Home, Movies,
/// Series and Live TV all observe, forcing a large synchronous re-render (the
/// catalog is filtered in-memory per playlist) plus a wave of poster loads — long
/// enough to read as a frozen UI. We surface that work: flip `isSwitching` first,
/// apply the selection one run-loop later so the overlay paints before the hitch,
/// then fade out once the new content has had a moment to settle.
@MainActor
@Observable
final class PlaylistSwitchModel {
    private(set) var isSwitching = false
    private(set) var targetName = ""

    /// Minimum time the overlay stays up after the selection is applied. There is
    /// no "content ready" signal to wait on (the per-playlist scope is a
    /// synchronous SwiftData filter), so this covers the re-render and the first
    /// wave of poster loads without flashing away instantly.
    private let settleDuration: Duration = .milliseconds(450)

    /// One-shot: set immediately before a switch whose caller wants the app to
    /// land in the cached catalog instead of handing the screen to the blocking
    /// auto-sync cover (minutes on a large playlist) — the tvOS quick-switch
    /// modal. The due sync is picked up by the next launch / foreground pass.
    @ObservationIgnored private var deferredDueSync = false

    /// Marks the next switch as one that skips the blocking auto-sync cover.
    /// Scoped to that one switch — the next one from Settings or the iOS/macOS
    /// switcher presents the cover again.
    func deferNextDueSync() {
        deferredDueSync = true
    }

    /// Reads and clears the deferral. Deliberately does not mark the playlist
    /// attempted: skipping the cover for this switch must not skip it for the
    /// rest of the session.
    func consumeDeferredDueSync() -> Bool {
        defer { deferredDueSync = false }
        return deferredDueSync
    }

    /// Begins a switch to `name`, deferring the caller's `apply` (the actual
    /// `@AppStorage` write) until the overlay is on screen.
    func switchTo(name: String, apply: @escaping () -> Void) {
        guard !isSwitching else { return }
        targetName = name
        isSwitching = true
        Task { @MainActor in
            // Defer the selection write so the overlay is committed before the
            // heavy re-render it triggers (see type doc).
            await Task.yield()
            apply()
            try? await Task.sleep(for: settleDuration)
            isSwitching = false
        }
    }
}

extension View {
    /// Layers the blocking switch-progress overlay over this view for whichever
    /// switch is in flight. The fade lives here rather than on the call site so
    /// the animated transaction covers the overlay layer only — attached to the
    /// tab hierarchy it would open one over every animatable attribute in every
    /// live tab.
    func switchProgressOverlay(playlist: PlaylistSwitchModel?, profile: ProfileManager?) -> some View {
        overlay {
            ZStack {
                if let message = switchProgressMessage(playlist: playlist, profile: profile) {
                    SwitchProgressOverlay(message: message)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: playlist?.isSwitching)
            .animation(.easeInOut(duration: 0.2), value: profile?.isSwitching)
        }
    }
}

/// The message for the switch in flight, or `nil` when none is. The profile case
/// stays up for the whole asynchronous re-projection, the playlist case for a
/// fixed settle.
private func switchProgressMessage(playlist: PlaylistSwitchModel?, profile: ProfileManager?) -> Text? {
    if let playlist, playlist.isSwitching {
        return Text(
            "Switching to \(playlist.targetName)",
            comment: "Loading message shown while the app switches to another IPTV playlist"
        )
    }
    if let profile, profile.isSwitching {
        return Text(
            "Switching profile to \(profile.pendingProfileName ?? "")",
            comment: "Loading message shown while the app switches to another user profile"
        )
    }
    return nil
}

/// The visual every switch shares.
private struct SwitchProgressOverlay: View {
    let message: Text

    var body: some View {
        ZStack {
            // Dim and capture taps so the half-rendered catalog isn't
            // interacted with mid-switch.
            Color.black.opacity(0.35)

            VStack(spacing: spacing) {
                ProgressView()
                    .controlSize(controlSize)
                    // Explicit white (not accentColor, which resolves to white on
                    // tvOS but reads as untinted elsewhere) over the dim backdrop.
                    .tint(.white)

                message
                    .font(font)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(padding)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    #if os(tvOS)
        private let spacing: CGFloat = 32
        private let padding: CGFloat = 56
        private let controlSize: ControlSize = .extraLarge
        private let font: Font = .title2
    #else
        private let spacing: CGFloat = 20
        private let padding: CGFloat = 32
        private let controlSize: ControlSize = .large
        private let font: Font = .headline
    #endif
}

#Preview("Playlist") {
    SwitchProgressOverlay(message: Text(verbatim: "Switching to My IPTV"))
}

#Preview("Profile") {
    SwitchProgressOverlay(message: Text(verbatim: "Switching profile to Profile 2"))
}
