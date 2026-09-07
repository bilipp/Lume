//
//  TVOnboardingOverlay.swift
//  Lume
//
//  The tvOS "How Lume Works" guide: one focus-driven page per `OnboardingStep`,
//  including the two steps that only exist on the big screen (Quick Switch and
//  Multi-View).
//
//  Presented as a plain overlay, never a `fullScreenCover`: a tvOS cover always
//  self-dismisses on Menu, and neither `onExitCommand` nor
//  `interactiveDismissDisabled` stops it. The guide needs Menu for itself so
//  leaving that way records it as seen, exactly as Skip does.
//
//  It deliberately leaves `tv.quickSwitch.hintShown.v1` alone: the Play/Pause
//  hint still fires on the next Home visit, and this tour only introduces the
//  gesture rather than absorbing the hint.
//

#if os(tvOS)

    import SwiftUI

    struct TVOnboardingOverlay: View {
        /// Whether this is the first-launch pass rather than a re-read opened
        /// from Settings. The first-launch pass offers Skip and ends on the
        /// hand-off to the add-playlist form waiting behind it; a re-read has
        /// nothing to hand off to and ends on Done.
        var isModal = false

        /// Called when the viewer leaves the guide — Skip, Menu, or the final
        /// button. The caller owns both the dismissal and the
        /// `onboarding.seenVersion.v1` write, so all three routes mark it seen.
        var onFinish: () -> Void

        /// The page the guide rests on. `@State` on purpose: backgrounding
        /// mid-guide resumes on the same step, and no per-step progress is
        /// persisted.
        @State private var stepIndex = 0

        @FocusState private var focus: FocusTarget?

        private enum FocusTarget: Hashable {
            case next
            case skip
        }

        private var steps: [OnboardingStep] {
            OnboardingStep.steps
        }

        private var step: OnboardingStep? {
            steps.indices.contains(stepIndex) ? steps[stepIndex] : steps.last
        }

        private var isLastStep: Bool {
            stepIndex >= steps.count - 1
        }

        var body: some View {
            VStack(spacing: 32) {
                header
                stepCard
                pageDots
                actions
                Text("Press Menu to close")
                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: TVSettingsMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.vertical, 60)
            .tvSettingsBackground()
            .defaultFocus($focus, .next, priority: .userInitiated)
            .onAppear(perform: landInitialFocus)
            .onExitCommand(perform: onFinish)
        }

        // MARK: - Content

        private var header: some View {
            VStack(spacing: 8) {
                Text(
                    "How Lume Works",
                    comment: "Title of the first-launch guide and of the Settings row that re-opens it"
                )
                .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                .foregroundStyle(.white)
                Text(
                    "A quick tour of the app. It takes less than a minute.",
                    comment: "Subtitle under the first-launch guide's title"
                )
                .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                .foregroundStyle(.secondary)
            }
        }

        /// A fixed height so the button row below never shifts as pages of
        /// different copy lengths come and go — a moving focus target under a
        /// resting focus is how the engine loses it.
        @ViewBuilder
        private var stepCard: some View {
            if let step {
                VStack(spacing: 20) {
                    // `.white`, never `.tint` / `Color.accentColor`, which
                    // resolve to flat white on tvOS anyway and read as unstyled.
                    Image(systemName: step.systemImage)
                        .font(.system(size: 76))
                        .foregroundStyle(.white)
                        .frame(height: 92)
                    Text(step.title)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                    Text(step.subtitle)
                        .font(.system(size: TVSettingsMetrics.rowFontSize))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        // The card height is fixed, so long copy has to shrink
                        // rather than truncate: the English "Lume is a player"
                        // subtitle already wanted a third line, and de/ja run
                        // longer still.
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .background(
                    RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .id(step.id)
                .transition(.opacity)
            }
        }

        /// Plain shapes, no focus targets — the remote pages with Continue.
        private var pageDots: some View {
            HStack(spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, _ in
                    Circle()
                        .fill(Color.white.opacity(index == stepIndex ? 0.9 : 0.25))
                        .frame(width: 12, height: 12)
                }
            }
        }

        /// One focus section, so left/right walks the buttons instead of
        /// wandering into whatever the guide is layered over.
        private var actions: some View {
            HStack(spacing: 20) {
                Button(action: advance) {
                    Text(primaryTitle)
                }
                .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                .focused($focus, equals: .next)
                .accessibilityIdentifier("onboarding.continue")

                if isModal {
                    Button(action: onFinish) {
                        Text(
                            "Skip",
                            comment: "Button that closes the first-launch guide without reading it"
                        )
                    }
                    .buttonStyle(TVSettingsActionButtonStyle())
                    .focused($focus, equals: .skip)
                    .accessibilityIdentifier("onboarding.skip")
                }
            }
            .focusSection()
        }

        private var primaryTitle: LocalizedStringResource {
            guard isLastStep else {
                return LocalizedStringResource(
                    "Continue",
                    comment: "Button that advances the first-launch guide to the next page"
                )
            }
            return isModal ? "Add Playlist" : "Done"
        }

        // MARK: - Paging

        private func advance() {
            guard !isLastStep else {
                onFinish()
                return
            }
            // The press is delivered inside the focus engine's animated context.
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) { stepIndex += 1 }
            }
        }

        // MARK: - Focus

        /// Asserts the initial focus once the tree has mounted: the engine picks
        /// its own target as the buttons appear, and a write made in the same
        /// turn is overwritten. Released first — two assertions in flight leave
        /// the engine on the incumbent.
        private func landInitialFocus() {
            Task { @MainActor in
                focus = nil
                try? await Task.sleep(for: .milliseconds(150))
                focus = .next
            }
        }
    }

#endif
