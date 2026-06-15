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

/// Full-screen blocking overlay shown while a playlist switch is in progress.
struct PlaylistSwitchOverlay: View {
    let playlistName: String

    var body: some View {
        ZStack {
            // Dim and capture taps so the half-rendered new playlist isn't
            // interacted with mid-switch.
            Color.black.opacity(0.35)

            VStack(spacing: spacing) {
                ProgressView()
                    .controlSize(controlSize)
                    // Explicit white (not accentColor, which resolves to white on
                    // tvOS but reads as untinted elsewhere) over the dim backdrop.
                    .tint(.white)

                Text(
                    "Switching to \(playlistName)",
                    comment: "Loading message shown while the app switches to another IPTV playlist"
                )
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

#Preview {
    PlaylistSwitchOverlay(playlistName: "My IPTV")
}
