//
//  TVQuickSwitchHint.swift
//  Lume
//
//  One-time teaching hint for the Play/Pause quick-switch gesture, shown over
//  the tvOS Home screen on first run.
//

#if os(tvOS)

    import SwiftUI

    extension View {
        /// Overlays the first-run Play/Pause hint. Drawn in an overlay and built
        /// from plain `Text`/`Image`, so it adds no focus target and cannot change
        /// the geometry of what it covers — the tab bar's up-handoff sentinel and
        /// the hero fold's snap both depend on that geometry staying put.
        ///
        /// `interacted` carries the host view's own signal that the viewer has
        /// moved on (a title was picked); the modal and tab-change signals are
        /// read from the router in the leaf, so observing them never re-renders
        /// the host. The remote is never read directly.
        func tvQuickSwitchHint(interacted: Bool) -> some View {
            modifier(TVQuickSwitchHintOverlay(interacted: interacted))
        }
    }

    private struct TVQuickSwitchHintOverlay: ViewModifier {
        let interacted: Bool

        /// Device-local on purpose: a hint already seen on this Apple TV says
        /// nothing about the user's other devices, so it is deliberately not
        /// mirrored to CloudKit.
        @AppStorage("tv.quickSwitch.hintShown.v1") private var hasBeenShown = false
        @Environment(DeepLinkRouter.self) private var router

        @State private var isVisible = false

        /// Left long enough to read once, short enough that it never competes
        /// with the hero for attention.
        private static let visibleDuration: Duration = .seconds(8)

        /// Lets the hero fold settle and take initial focus before the hint
        /// fades in over it.
        private static let appearDelay: Duration = .milliseconds(600)

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .bottom) {
                    if isVisible {
                        TVQuickSwitchHintBanner()
                            .transition(.opacity)
                    }
                }
                .task {
                    guard !hasBeenShown else { return }
                    try? await Task.sleep(for: Self.appearDelay)
                    withAnimation(.easeInOut(duration: 0.3)) { isVisible = true }
                    try? await Task.sleep(for: Self.visibleDuration)
                    dismiss()
                }
                .onChange(of: hasMovedOn) { _, moved in
                    guard moved else { return }
                    // The signals feeding this fire inside the focus engine's
                    // animated context.
                    Task { @MainActor in dismiss() }
                }
                // Home can unmount before the timeout — a hint that was on
                // screen still counts as shown, which `dismiss()` records.
                .onDisappear(perform: dismiss)
        }

        /// The viewer has moved on: a title was picked, the quick-switch modal
        /// opened, or another tab took over. Guarded on `hasBeenShown` so that
        /// once the hint is spent nothing here observes the router any more.
        private var hasMovedOn: Bool {
            guard !hasBeenShown else { return false }
            return interacted || router.isQuickSwitchPresented || router.selectedTab != .home
        }

        private func dismiss() {
            guard isVisible else { return }
            withAnimation(.easeInOut(duration: 0.3)) { isVisible = false }
            hasBeenShown = true
        }
    }

    private struct TVQuickSwitchHintBanner: View {
        var body: some View {
            HStack(spacing: 16) {
                Image(systemName: "playpause.fill")
                Text(
                    "Press Play/Pause to switch playlist or profile",
                    comment: "First-run hint on the tvOS Home screen teaching the Play/Pause remote button that opens the playlist/profile quick-switch modal"
                )
            }
            .font(.system(size: TVSettingsMetrics.rowFontSize, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.75), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .padding(.bottom, 60)
            .allowsHitTesting(false)
        }
    }

#endif
